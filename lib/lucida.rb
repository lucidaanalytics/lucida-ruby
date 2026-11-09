# frozen_string_literal: true

require "json"
require "logger"
require_relative "lucida/wire"
require_relative "lucida/context"
require_relative "lucida/test_mode"
require_relative "lucida/evaluator"
require_relative "lucida/delivery"
require_relative "lucida/flag_cache"
require_relative "lucida/flag_snapshot"
require_relative "lucida/identity"
require_relative "lucida/flags"

# Server SDK for Lucida (stdlib only). Pass a distinct_id on every call, or set one for the request with
# Lucida.with_context.
module Lucida
  VERSION = "0.1.0"
  LIB = "lucida-ruby"

  # rubocop:disable Metrics/ClassLength
  class Client
    include Delivery
    include Flags
    include Identity

    attr_reader :dropped_events, :sink

    # transport: ->(url, body, headers) { status or [status, retry_after, body, etag] } overrides HTTP (tests);
    #   body is nil for GET. sleeper: ->(seconds) overrides sleep between retries (tests).
    # on_error: ->(Lucida::Error) for batches that were dropped or could not be delivered.
    # before_send: ->(event_hash) returning the event to send, nil to drop it; raising keeps the original.
    # flush_at triggers a flush; max_batch_size caps one request. flush_interval/flag_poll_interval of 0 disable the threads.
    # fallbacks: { flag_key => value } served (reason "fallback", no exposure) when a flag read fails or the flag is unknown.
    # sync_mode: send each event inline (no queue, no thread). test_mode: fixture (path, Hash or Array); offline,
    #   events land in `sink.events`.
    def initialize(api_key, host: "https://capture.lucidace.com", secret_key: nil, flush_at: 20, max_queue_size: 1000,
                   max_batch_size: 100, flush_interval: 5, flag_poll_interval: 30, max_retries: 3, retry_delay: 0.5,
                   timeout: 10, debug: false, logger: nil, on_error: nil, before_send: nil, sync_mode: false,
                   only_evaluate_locally: false, disabled: false, transport: nil, sleeper: nil, test_mode: nil,
                   app_contexts: nil, flag_definition_cache: nil, fallbacks: {})
      @api_key = api_key
      @host = host.sub(%r{/+\z}, "")
      @secret = secret_key
      @flush_at = flush_at
      @max = max_queue_size
      @batch_size = max_batch_size
      @flush_interval = flush_interval
      @poll_interval = flag_poll_interval
      @max_retries = max_retries
      @retry_delay = retry_delay
      @timeout = timeout
      @on_error = on_error
      @before_send = before_send
      @sync_mode = sync_mode
      @only_local = only_evaluate_locally || !test_mode.nil?
      @disabled = disabled
      @app_contexts = app_contexts
      @flag_cache = flag_definition_cache
      @fallbacks = (fallbacks || {}).transform_keys(&:to_s)
      @transport = test_mode ? TestMode.no_network : transport
      @sleeper = sleeper || method(:sleep)
      @logger = logger ? ->(m) { logger.debug(m) } : (debug ? Logger.new($stderr).method(:debug) : nil)
      @queue = []
      @seen = {}
      @defs = nil
      @etag = nil
      @dropped_events = 0
      @mutex = Mutex.new
      @sleep_mutex = Mutex.new
      @wake = ConditionVariable.new
      if test_mode
        @defs = TestMode.load_fixture(test_mode)
        @sink = Sink.new
      end
      start_threads
    end

    # distinct_id may be nil to use the Lucida.with_context one. `flags:` attaches a FlagSnapshot's `$feature/*`
    # properties; send_feature_flags: true evaluates the distinct id's flags first (no exposure events).
    # process_person_profile: false sends a personless
    # event (a random UUID distinct id is generated when none is available).
    def capture(distinct_id, event, properties = nil, groups: nil, timestamp: nil, uuid: nil, set: nil, set_once: nil,
                process_person_profile: true, send_feature_flags: false, flags: nil)
      return if @disabled

      ctx = Context.current
      props = @mutex.synchronize { super_props.dup }.merge(ctx[:properties]).merge(properties || {})
      props["$session_id"] = ctx[:session_id] if ctx[:session_id] && !props.key?("$session_id")
      props["$process_person_profile"] = false unless process_person_profile
      id = distinct_id || ctx[:distinct_id]
      props = attach_flags(id, props, groups, send_feature_flags, flags)
      id = SecureRandom.uuid if (id.nil? || id.to_s.empty?) && !process_person_profile
      return log("capture(#{event}) dropped: no distinct_id") if id.nil? || id.to_s.empty?

      enqueue(build_event(id, event, props, groups: groups, timestamp: timestamp, uuid: uuid, set: set,
                                            set_once: set_once))
    end

    # An identical call (same id and properties) already sent by this client is skipped.
    def identify(distinct_id, properties = nil, properties_set_once = nil)
      return unless first_identity?("identify", distinct_id, properties, properties_set_once)

      capture(distinct_id, "$identify", set: properties, set_once: properties_set_once)
    end

    def alias(distinct_id, alias_id)
      capture(distinct_id, "$create_alias", { "alias" => alias_id, "distinct_id" => distinct_id })
    end

    def group_identify(group_type, group_key, properties = nil, distinct_id = nil)
      return unless first_identity?("group", group_type, group_key, distinct_id, properties)

      capture(distinct_id || "$#{group_type}_#{group_key}", "$groupidentify",
              { "$group_type" => group_type, "$group_key" => group_key, "$group_set" => properties || {} })
    end

    private

    def build_event(distinct_id, event, properties, groups: nil, timestamp: nil, uuid: nil, set: nil, set_once: nil)
      e = { "uuid" => uuid || Wire.uuid7, "event" => event, "distinct_id" => distinct_id,
            "timestamp" => Wire.iso(timestamp),
            "properties" => (properties || {}).merge("$lib" => LIB, "$lib_version" => VERSION) }
      e["$set"] = set if set && !set.empty?
      e["$set_once"] = set_once if set_once && !set_once.empty?
      e["$groups"] = groups if groups && !groups.empty?
      e
    end
  end
  # rubocop:enable Metrics/ClassLength

  class << self
    # Process-wide client used by integrations (lucida-rails); set it once at boot.
    attr_accessor :client

    # Runs the block with an ambient distinct id / session id / properties (Thread and Fiber local).
    def with_context(**opts, &) = Context.with(**opts, &)

    def current_context = Context.current

    def context_from_headers(headers) = Context.from_headers(headers)

    def after_fork = client&.after_fork
  end
end
