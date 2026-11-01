# frozen_string_literal: true

module Lucida
  # Flag evaluation for Client: local definitions (polled, ETag aware) with a remote /v1/flags fallback for
  # flags the definitions cannot decide (cohorts etc.), unless only_evaluate_locally.
  module Flags
    # reason is the evaluator's (local) or the server's (remote) reason string.
    FlagResult = Struct.new(:key, :value, :payload, :reason, :locally_evaluated, :request_id) do
      def enabled? = value != false
      def variant = value.is_a?(String) ? value : nil
    end

    # Fetches definitions (needs secret_key). Keeps the previous ones on any failure.
    def reload_feature_flags
      return false unless @secret && !@disabled

      cached = FlagCache.adopt(@flag_cache)
      if cached
        @defs = cached
        return true
      end
      headers = { "Authorization" => "Bearer #{@secret}" }
      headers["If-None-Match"] = @etag if @etag
      res = request("#{@host}/v1/flags/definitions", nil, headers)
      return true if res.status == 304

      flags = ok?(res) ? JSON.parse(res.body.to_s)["flags"] : nil
      return false unless flags.is_a?(Array)

      @defs = flags
      @etag = res.etag
      FlagCache.publish(@flag_cache, flags)
      true
    rescue JSON::ParserError
      false
    end

    # Test hook / bootstrap: use these definitions without fetching.
    def definitions=(flags)
      @defs = flags
    end

    # Full result (value, payload, reason) or nil when unknown / undecidable. Records exposure unless send_exposure: false.
    def get_feature_flag_result(key, distinct_id = nil, send_exposure: true, **opts)
      id = distinct_id || Context.current[:distinct_id]
      return nil if @disabled || id.nil?

      r = resolve(key, id, opts)
      expose(id, r) if r && send_exposure
      r
    end

    # False, true or a variant key; nil when unknown or undecidable.
    def get_feature_flag(key, distinct_id = nil, **opts) = get_feature_flag_result(key, distinct_id, **opts)&.value

    def is_feature_enabled(key, distinct_id = nil, **opts)
      v = get_feature_flag(key, distinct_id, **opts)
      v.nil? ? nil : v != false
    end

    def get_feature_flag_payload(key, distinct_id = nil, **opts)
      get_feature_flag_result(key, distinct_id, send_exposure: false, **opts)&.payload
    end

    # { key => value } for every flag decidable locally (plus remote ones unless only_evaluate_locally); no exposures.
    def get_all_flags(distinct_id = nil, **opts) = all_results(distinct_id, opts).transform_values(&:value)

    # { "flags" => {key => value}, "payloads" => {key => payload} } (payloads only where present).
    def get_all_flags_and_payloads(distinct_id = nil, **opts)
      all = all_results(distinct_id, opts)
      { "flags" => all.transform_values(&:value),
        "payloads" => all.each_with_object({}) { |(k, r), h| h[k] = r.payload unless r.payload.nil? } }
    end

    # Evaluate every flag once; read the snapshot freely and pass it to `capture(..., flags: snapshot)`.
    def evaluate_flags(distinct_id = nil, **opts)
      all = all_results(distinct_id, opts)
      FlagSnapshot.new(all.transform_values(&:value),
                       all.each_with_object({}) { |(k, r), h| h[k] = r.payload unless r.payload.nil? })
    end

    # Payload of a remote-config flag, decrypted when stored encrypted. Needs secret_key (the server only opens
    # encrypted payloads for secret keys). nil when unknown or on failure.
    def get_remote_config_payload(key)
      raise ArgumentError, "get_remote_config_payload requires secret_key" unless @secret
      return nil if @disabled

      escaped = key.to_s.b.gsub(/[^A-Za-z0-9\-._~]/) { |c| format("%%%02X", c.ord) }
      res = request("#{@host}/v1/flags/#{escaped}/remote-config", nil, { "Authorization" => "Bearer #{@secret}" })
      ok?(res) ? JSON.parse(res.body.to_s)["payload"] : nil # 404: unknown or not a remote-config flag
    rescue JSON::ParserError
      nil
    end

    private

    def attach_flags(id, props, groups, send_feature_flags, snapshot)
      if snapshot
        FlagSnapshot.event_props(props, snapshot.values)
      elsif send_feature_flags && id
        values = all_results(id, groups: groups).transform_values(&:value)
        FlagSnapshot.event_props(props, values)
      else
        props
      end
    end

    def flag_ctx(id, o)
      { "distinct_id" => id, "groups" => o[:groups] || {}, "person_properties" => o[:person_properties] || {},
        "group_properties" => o[:group_properties] || {},
        "app_contexts" => o[:app_contexts] || @app_contexts || [] }
    end

    def only_local?(o) = o.fetch(:only_evaluate_locally, @only_local)

    def local_result(r, key)
      FlagResult.new(key, r.value, r.payload, r.reason, true, nil)
    end

    # Locally decided results; second element is true when something needs the server (or no definitions yet).
    def local_all(id, o)
      return [{}, true] if @defs.nil?

      all = Evaluator.evaluate_all(@defs, flag_ctx(id, o))
      all = all.reject { |_, r| r.reason == "app_context_excluded" }
      decided = all.reject { |_, r| r.reason == Evaluator::REQUIRES_SERVER }
      [decided.to_h { |k, r| [k, local_result(r, k)] }, decided.size != all.size]
    end

    def resolve(key, id, o)
      local = local_all(id, o).first[key]
      return local if local || only_local?(o)

      remote(id, o, [key])[key]
    end

    def all_results(distinct_id, o)
      id = distinct_id || Context.current[:distinct_id]
      return {} if @disabled || id.nil?

      res, undecided = local_all(id, o)
      remote(id, o, nil).each { |k, r| res[k] ||= r } if undecided && !only_local?(o)
      res
    end

    def remote(id, o, keys)
      body = { "api_key" => @api_key, "distinct_id" => id, "groups" => o[:groups] || {},
               "person_properties" => o[:person_properties] || {}, "group_properties" => o[:group_properties] || {} }
      body["flag_keys"] = keys if keys
      ac = o[:app_contexts] || @app_contexts
      body["app_contexts"] = ac if ac && !ac.empty?
      # Pre-identify id (option `anon_distinct_id`): the gateway links it so flags keep their bucket.
      body["anon_distinct_id"] = o[:anon_distinct_id] if o[:anon_distinct_id]
      res = post_with_retry("/v1/flags", body)
      return {} unless ok?(res)

      parse_remote(JSON.parse(res.body.to_s))
    rescue JSON::ParserError
      {}
    end

    def parse_remote(j)
      return {} unless j.is_a?(Hash) && j["flags"].is_a?(Hash)

      j["flags"].to_h do |k, f|
        v = f["value"]
        v = f["variant"] || (f["enabled"] ? true : false) if v.nil?
        [k, FlagResult.new(k, v, f["payload"], f["reason"] || "remote", false, j["request_id"])]
      end
    end

    def expose(distinct_id, r)
      seen = "#{distinct_id}\0#{r.key}\0#{r.value}"
      return if @seen.key?(seen)

      @seen.clear if @seen.size >= 10_000
      @seen[seen] = true
      props = { "$feature_flag" => r.key, "$feature_flag_response" => r.value, "locally_evaluated" => r.locally_evaluated }
      props["$feature_flag_request_id"] = r.request_id if r.request_id
      capture(distinct_id, "$feature_flag_called", props)
      capture(distinct_id, "$exposure", props.dup)
    end
  end
end
