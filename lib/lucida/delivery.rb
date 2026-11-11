# frozen_string_literal: true

require "net/http"
require "uri"

module Lucida
  class Error < StandardError
    attr_reader :status

    def initialize(message, status = nil)
      super(message)
      @status = status
    end
  end

  # Queue, background flush thread, retry/backoff and HTTP for Client. Expects the including class to set
  # @queue @mutex @host @api_key @secret @disabled @transport and the option ivars read below.
  module Delivery
    # Sends everything queued (batches of max_batch_size). Returns false when a batch could not be delivered.
    def flush
      ok = true
      loop do
        batch = @mutex.synchronize { @queue.shift(@batch_size) }
        break if batch.empty?

        next if send_batch(batch)

        @mutex.synchronize { @queue.unshift(*batch) } # keep for the next flush; bounded by max_queue_size
        ok = false
        break
      end
      ok
    end

    def shutdown
      stop_threads
      @flag_cache&.shutdown
      flush
      @disabled = true
    end

    # Call from a forked child (Puma/Unicorn on_worker_boot, Spring): threads and mutexes do not survive fork(2).
    # Also runs lazily on the first capture after a pid change. The child drops the parent's queued events.
    def after_fork
      @mutex = Mutex.new
      @sleep_mutex = Mutex.new
      @wake = ConditionVariable.new
      @queue = []
      start_threads
    end

    # Historical import via POST /v1/s2s/batch (secret key, caller timestamps kept), chunks of 1000.
    # Events are hashes with distinct_id, event and optional properties/timestamp/uuid/set/set_once.
    # Default properties, context properties and before_send apply (an event the hook drops is not sent);
    # `raw: true` sends the events as given.
    def import_events(events, raw: false)
      raise Error, "import_events requires secret_key" unless @secret
      return 0 if @disabled

      wire = events.filter_map { |e| import_wire(e, raw) }
      return wire.each { |w| @sink.add(w) }.size if @sink

      sent = 0
      wire.each_slice(1000) do |chunk|
        res = post_with_retry("/v1/s2s/batch", { "batch" => chunk, "sent_at" => Wire.iso(nil) },
                              "Authorization" => "Bearer #{@secret}")
        raise Error.new("import failed: status #{res.status} after #{sent} events", res.status) unless ok?(res)

        sent += chunk.size
      end
      sent
    end

    private

    def ok?(res) = res.status.between?(200, 299)

    def import_wire(e, raw)
      g = ->(k) { e[k] || e[k.to_s] }
      props = raw ? g.call(:properties) : @mutex.synchronize { super_props.dup }.merge(g.call(:properties) || {})
      event = build_event(g.call(:distinct_id), g.call(:event), props, timestamp: g.call(:timestamp),
                                                                       uuid: g.call(:uuid), set: g.call(:set), set_once: g.call(:set_once))
      raw ? event : apply_before_send(event)
    end

    def enqueue(event)
      event = apply_before_send(event)
      return if event.nil?
      return @sink.add(event) && nil if @sink
      if @sync_mode
        release_identities([event]) unless send_batch([event])
        return nil
      end

      after_fork if @pid && @pid != Process.pid
      dropped = nil
      n = @mutex.synchronize do
        if @queue.size >= @max
          dropped = @queue.shift
          @dropped_events += 1
        end
        @queue << event
        @queue.size
      end
      release_identities([dropped]) if dropped
      flush if n >= @flush_at
      nil
    end

    # nil from the hook drops the event; an exception keeps the original.
    def apply_before_send(event)
      @before_send ? @before_send.call(event) : event
    rescue StandardError => e
      log("before_send raised: #{e.message}")
      event
    end

    # True when delivered or permanently rejected (dropped); false when retries ran out on a retryable failure.
    def send_batch(batch)
      res = post_with_retry("/v1/batch", { "api_key" => @api_key, "batch" => batch, "sent_at" => Wire.iso(nil) })
      return true if ok?(res)

      retry_later = Wire.retryable?(res.status)
      release_identities(batch) unless retry_later
      report(Error.new("batch of #{batch.size} events #{retry_later ? 'kept for next flush' : 'dropped'}: " \
                       "status #{res.status}", res.status))
      !retry_later
    end

    def post_with_retry(path, payload, extra_headers = {})
      url, body = Wire.encode("#{@host}#{path}", payload)
      headers = { "Content-Type" => "application/json" }.merge(extra_headers)
      attempt = 0
      loop do
        res = request(url, body, headers)
        return res if ok?(res) || !Wire.retryable?(res.status) || attempt >= @max_retries

        @sleeper.call(backoff(attempt, res.retry_after))
        attempt += 1
      end
    end

    def backoff(attempt, retry_after)
      [[30.0, @retry_delay * (2**attempt)].min * (0.5 + (0.5 * rand)), retry_after.to_f].max
    end

    # body nil means GET. Never raises: transport errors become status 0.
    def request(url, body, headers)
      Wire.response(@transport ? @transport.call(url, body, headers) : http_request(url, body, headers))
    rescue StandardError => e
      log("request failed: #{e.message}")
      Wire::Response.new(0)
    end

    def http_request(url, body, headers)
      u = URI(url)
      Net::HTTP.start(u.host, u.port, use_ssl: u.scheme == "https", open_timeout: @timeout, read_timeout: @timeout) do |h|
        r = body.nil? ? h.get(u.request_uri, headers) : h.post(u.request_uri, body, headers)
        [r.code.to_i, Wire.parse_retry_after(r["retry-after"]), r.body, r["etag"]]
      end
    end

    def report(error)
      log(error.message)
      @on_error&.call(error)
    rescue StandardError => e
      log("on_error raised: #{e.message}")
    end

    def log(msg) = (@logger&.call("[lucida] #{msg}"))

    # Background threads ---------------------------------------------------------------------

    def start_threads
      @pid = Process.pid
      @stopping = false
      return if @sink || @disabled

      @flusher = Thread.new { every(@flush_interval) { flush } } if @flush_interval.to_f.positive? && !@sync_mode
      @poller = Thread.new { every(@poll_interval, now: true) { reload_feature_flags } } if poll_flags?
    end

    def poll_flags? = @secret && @poll_interval.to_f.positive?

    def every(interval, now: false)
      yield if now
      until @stopping
        @sleep_mutex.synchronize { @wake.wait(@sleep_mutex, interval) }
        break if @stopping

        begin
          yield
        rescue StandardError => e
          log("background task failed: #{e.message}")
        end
      end
    end

    def stop_threads
      @stopping = true
      @sleep_mutex.synchronize { @wake.broadcast }
      [@flusher, @poller].compact.each { |t| t.join(1) unless t == Thread.current }
    end
  end
end
