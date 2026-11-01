# frozen_string_literal: true

require "digest"
require_relative "ops_v2"

module Lucida
  # Local flag evaluator; behaviour pinned by testdata/flags vectors (see testdata/flags/README.md).
  module Evaluator
    REQUIRES_SERVER = "requires_server"
    UNIT = 4_503_599_627_370_496.0 # 16**13

    Result = Struct.new(:value, :reason, :condition_index, :variant, :payload)

    module_function

    def hash01(text)
      Digest::SHA256.hexdigest(text)[0, 13].to_i(16) / UNIT
    end

    def off(reason, idx = -1)
      Result.new(false, reason, idx)
    end

    def num?(v)
      v.is_a?(Numeric)
    end

    def to_float(v)
      return v.to_f if num?(v)
      return Float(v.strip) if v.is_a?(String) && !v.include?("_")

      nil
    rescue ArgumentError
      nil
    end

    def equal?(a, b)
      return num?(a) && num?(b) && a.to_f == b.to_f if num?(a) || num?(b)

      a == b
    end

    def semver(v)
      return nil unless v.is_a?(String)

      s = v.strip.sub(/\Av/, "").split(/[-+]/, 2).first.to_s
      parts = s.split(".", -1)
      !parts.empty? && parts.all? { |p| p.match?(/\A[0-9]+\z/) } ? parts.map(&:to_i) : nil
    end

    def cmp_semver(a, b)
      pa = semver(a)
      pb = semver(b)
      return nil if pa.nil? || pb.nil?

      n = [pa.size, pb.size].max
      pa += [0] * (n - pa.size)
      pb += [0] * (n - pb.size)
      pa <=> pb
    end

    def regex(pattern, s)
      Regexp.new(pattern).match?(s)
    rescue RegexpError
      nil
    end

    def match?(op, prop, present, want, semver, now = nil)
      is_set = present && !prop.nil?
      return is_set if op == "is_set"
      return !is_set if op == "is_not_set"
      return false unless is_set

      case op
      when "eq", "neq"
        if semver
          c = cmp_semver(prop, want)
          return !c.nil? && (c.zero? == (op == "eq"))
        end
        equal?(prop, want) == (op == "eq")
      when "contains", "ncontains", "regex", "nregex"
        return false unless prop.is_a?(String) && want.is_a?(String)
        return prop.include?(want) == (op == "contains") if %w[contains ncontains].include?(op)

        r = regex(want, prop)
        !r.nil? && r == (op == "regex")
      when "gt", "gte", "lt", "lte"
        if semver
          c = cmp_semver(prop, want)
        else
          x = to_float(prop)
          y = to_float(want)
          c = x.nil? || y.nil? ? nil : x <=> y
        end
        return false if c.nil?

        { "gt" => c.positive?, "gte" => c >= 0, "lt" => c.negative?, "lte" => c <= 0 }[op]
      when "in", "not_in"
        return false unless want.is_a?(Array)

        want.any? { |w| equal?(prop, w) } == (op == "in")
      else
        OpsV2.match(op, prop, want, now || Time.now, method(:to_float), method(:semver), method(:cmp_semver))
      end
    end

    def filter_matches?(fl, c, resolved)
      t = fl["type"]
      want = fl["value"]
      now = OpsV2.parse_now(c["now"])
      case t
      when "app_version"
        v = c["app_version"] || ""
        return match?(fl["op"].to_s, v, v != "", want, true, now)
      when "flag"
        r = resolved[fl["key"].to_s]
        return !r.nil? && match?(fl["op"].to_s, r.value, true, want, false, now)
      when "person" then props = c["person_properties"]
      when "group" then props = (c["group_properties"] || {})[fl["group_type"].to_s]
      when "device" then props = c["device_properties"]
      when "geo" then props = c["geo_properties"]
      else return false
      end
      props ||= {}
      key = fl["key"].to_s
      match?(fl["op"].to_s, props[key], props.key?(key), want, false, now)
    end

    def value_matches?(got, want)
      return got == want unless want == true || want == false

      got == true || got == false ? got == want : want
    end

    def bucketing_key(f, c) = unit_key(f["aggregation"] || {}, c)

    def unit_key(agg, c)
      case agg["kind"]
      when "group" then ((c["groups"] || {})[agg["group_type"].to_s] || "").to_s
      when "device" then (c["device_id"] || "").to_s
      else
        k = c["bucketing_key"]
        (k.nil? || k == "" ? c["distinct_id"] : k).to_s
      end
    end

    def pick_variant(f, cond, key)
      variants = f["variants"]
      override = cond["variant_override"]
      if override && override != ""
        v = variants.find { |x| x["key"] == override }
        return v if v
      end
      h = hash01("#{f['key']}.#{f['salt']}.variant.#{key}") * 100
      cum = 0.0
      variants.each do |v|
        cum += (v["rollout_pct"] || 0)
        return v if h < cum
      end
      variants.last
    end

    def undecidable?(fl, resolved)
      if fl["type"] == "flag"
        r = resolved[fl["key"].to_s]
        return !r.nil? && r.reason == REQUIRES_SERVER
      end
      fl["type"] == "cohort"
    end

    # A stored value of a sticky flag decides once a condition's filters passed (LC-EXT-29).
    def sticky(f, cond, idx, c)
      stored = (c["sticky_assignments"] || {})[f["key"]] if f["sticky"]
      return nil if stored.nil?

      variants = f["variants"] || []
      if f["type"] == "multivariate" && !variants.empty?
        return nil if variants.any? { |v| v["key"] == cond["variant_override"] } # the override wins

        v = variants.find { |x| stored.is_a?(String) && x["key"] == stored }
        return v && Result.new(v["key"], "sticky_bucket", idx, v["key"], v["payload"])
      end
      return nil unless stored == true

      Result.new(true, "sticky_bucket", idx, nil, f["type"] == "json" ? f["payload"] : nil)
    end

    def app_context_allowed?(f, c)
      want = f["app_contexts"] || []
      have = c["app_contexts"] || []
      want.empty? || have.empty? || want.any? { |x| have.include?(x) }
    end

    def evaluate(f, c, resolved)
      return off("app_context_excluded") unless app_context_allowed?(f, c)
      return off("inactive") unless f["active"]
      return off("kill_switch") if f["kill_switch"]

      server = false
      (f["prerequisites"] || []).each do |p|
        r = resolved[p["flag"]]
        return off("prerequisite_missing") if r.nil?

        if r.reason == REQUIRES_SERVER
          server = true
        elsif r.reason == "prerequisite_cycle" || !value_matches?(r.value, p["value"])
          return off("prerequisite_failed")
        end
      end
      return off(REQUIRES_SERVER) if server

      key = bucketing_key(f, c)
      conds = f["conditions"] || []
      per_condition = conds.any? { |cd| cd["aggregation"] }
      return off("no_bucketing_key") if key.empty? && (!per_condition || f["holdout"] || f["namespace"])

      ho = f["holdout"]
      return off("holdout") if ho && hash01("holdout.#{ho['salt']}.#{key}") * 100 < ho["percentage"]

      ns = f["namespace"]
      if ns && ns["total"].to_i.positive?
        b = (hash01("namespace.#{ns['salt']}.#{key}") * ns["total"]).floor
        return off("namespace_excluded") if b < ns["start"] || b >= ns["end"]
      end
      skipped = 0
      conds.each_with_index do |cond, i|
        ckey = cond["aggregation"] ? unit_key(cond["aggregation"], c) : key
        if ckey.empty?
          skipped += 1
          next
        end
        filters = cond["filters"] || []
        next unless filters.reject { |fl| undecidable?(fl, resolved) }.all? { |fl| filter_matches?(fl, c, resolved) }
        return off(REQUIRES_SERVER, i) if filters.any? { |fl| undecidable?(fl, resolved) }

        stuck = cond["aggregation"] ? nil : sticky(f, cond, i, c) # the store keys on the flag-level unit
        return stuck if stuck

        if hash01("#{f['key']}.#{f['salt']}.#{ckey}") * 100 >= (cond["rollout_pct"] || 0)
          return off("out_of_rollout", i) if f["early_exit"]

          next
        end

        if f["type"] == "multivariate" && !(f["variants"] || []).empty?
          v = pick_variant(f, cond, ckey)
          return Result.new(v["key"], "condition_match", i, v["key"], v["payload"])
        end
        return Result.new(true, "condition_match", i, nil, f["type"] == "json" ? f["payload"] : nil)
      end
      off(!conds.empty? && skipped == conds.size ? "no_bucketing_key" : "no_condition_match")
    end

    def deps(f)
      d = (f["prerequisites"] || []).map { |p| p["flag"] }
      (f["conditions"] || []).each do |cond|
        (cond["filters"] || []).each { |fl| d << fl["key"] if fl["type"] == "flag" }
      end
      d
    end

    # Evaluate every flag, resolving prerequisites and `flag` filters depth-first.
    def evaluate_all(flags, ctx)
      by_key = flags.to_h { |f| [f["key"], f] }
      out = {}
      state = {}
      visit = lambda do |key|
        f = by_key[key]
        next if f.nil? || state.key?(key)

        state[key] = 1
        cyc = false
        deps(f).each do |dep|
          visit.call(dep)
          cyc = true if state[dep] == 1 || (out.key?(dep) && out[dep].reason == "prerequisite_cycle")
        end
        out[key] = cyc ? off("prerequisite_cycle") : evaluate(f, ctx, out)
        state[key] = 2
      end
      flags.each { |f| visit.call(f["key"]) }
      out
    end
  end
end
