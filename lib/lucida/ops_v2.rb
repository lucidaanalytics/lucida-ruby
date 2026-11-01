# frozen_string_literal: true

require "time"
require "date"

module Lucida
  # Spec v2 operators (testdata/flags/README.md, "Spec v2"); port of go/internal/flageval/ops_v2.go.
  module OpsV2
    REL = /\A-?(\d{1,6})([hdwmy])\z/
    UNIT = { "h" => 3600, "d" => 86_400, "w" => 7 * 86_400, "m" => 30 * 86_400, "y" => 365 * 86_400 }.freeze
    RFC3339 = /\A\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}(\.\d+)?(Z|[+-]\d{2}:\d{2})\z/
    DATE = /\A\d{4}-\d{2}-\d{2}\z/
    STRING_OPS = %w[icontains not_icontains starts_with not_starts_with ends_with not_ends_with].freeze
    SEMVER_CMP = %w[semver_eq semver_neq semver_gt semver_gte semver_lt semver_lte].freeze
    SEMVER_RANGE = %w[semver_tilde semver_caret semver_wildcard].freeze

    module_function

    def num?(v) = v.is_a?(Numeric)

    def relative_seconds(s)
      m = REL.match(s.strip)
      m && (m[1].to_i * UNIT[m[2]])
    end

    def parse_now(s)
      s.is_a?(String) && RFC3339.match?(s) ? Time.parse(s) : Time.now
    rescue ArgumentError
      Time.now
    end

    def instant(v, now, rel)
      return Time.at(v) if num?(v)
      return nil unless v.is_a?(String)

      s = v.strip
      if rel && (secs = relative_seconds(s))
        return now - secs
      end
      return Time.parse(s) if RFC3339.match?(s)
      return Time.utc(*s.split("-").map(&:to_i)) if DATE.match?(s) && Date.valid_date?(*s.split("-").map(&:to_i))

      nil
    rescue ArgumentError
      nil
    end

    def semver_range(op, want, parse)
      return nil unless want.is_a?(String)

      parts = want.strip.sub(/\Av/, "").split(".", -1)
      if op == "semver_wildcard"
        return nil unless %w[* x X].include?(parts.last)
        return [[0], [1 << 30]] if parts.size == 1

        lo = parse.call(parts[0..-2].join("."))
        return lo && [lo, lo[0..-2] + [lo[-1] + 1]]
      end
      p = parse.call(want)
      return nil if p.nil?

      p += [0] * (3 - p.size)
      a, b, c = p
      hi = if op == "semver_tilde" && parts.size == 1 then [a + 1, 0, 0]
           elsif op == "semver_tilde" || (a.zero? && b.positive?) then [a, b + 1, 0]
           elsif a.positive? then [a + 1, 0, 0]
           else [0, 0, c + 1]
           end
      [p, hi]
    end

    def cmp_parts(a, b)
      n = [a.size, b.size].max
      (a + [0] * (n - a.size)) <=> (b + [0] * (n - b.size))
    end

    def string_op(op, prop, want)
      return false unless prop.is_a?(String) && want.is_a?(String)

      case op
      when "icontains", "not_icontains" then prop.downcase.include?(want.downcase) == (op == "icontains")
      when "starts_with", "not_starts_with" then prop.start_with?(want) == (op == "starts_with")
      else prop.end_with?(want) == (op == "ends_with")
      end
    end

    # to_float: v -> Float|nil, parse: v -> [Integer]|nil, cmp_semver: (a, b) -> Integer|nil
    def match(op, prop, want, now, to_float, parse, cmp_semver) # rubocop:disable Metrics/ParameterLists
      return string_op(op, prop, want) if STRING_OPS.include?(op)

      case op
      when "between", "not_between"
        x = to_float.call(prop)
        return false unless want.is_a?(Array) && want.size == 2 && !x.nil? && want.all? { |w| num?(w) }

        (want[0] <= x && x <= want[1]) == (op == "between")
      when "is_date_before", "is_date_after"
        p = instant(prop, now, false)
        w = instant(want, now, true)
        return false if p.nil? || w.nil?

        op == "is_date_before" ? p < w : p > w
      when *SEMVER_RANGE
        v = parse.call(prop)
        r = semver_range(op, want, parse)
        !v.nil? && !r.nil? && cmp_parts(v, r[0]) >= 0 && cmp_parts(v, r[1]).negative?
      when *SEMVER_CMP
        c = cmp_semver.call(prop, want)
        return false if c.nil?

        { "semver_eq" => c.zero?, "semver_neq" => !c.zero?, "semver_gt" => c.positive?, "semver_gte" => c >= 0,
          "semver_lt" => c.negative?, "semver_lte" => c <= 0 }[op]
      else
        false
      end
    end
  end
end
