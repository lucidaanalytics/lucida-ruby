# frozen_string_literal: true

module Lucida
  # Request-scoped ambient identity (Thread/Fiber-local stack). Explicit capture arguments always win.
  module Context
    KEY = :lucida_context_stack
    HEADER_DISTINCT = "x-lucida-distinct-id"
    HEADER_SESSION = "x-lucida-session-id"
    EMPTY = { distinct_id: nil, session_id: nil, properties: {} }.freeze

    module_function

    def stack = (Thread.current[KEY] ||= [])

    def current = stack.last || EMPTY

    # Runs the block with a context layered over the current one; `fresh: true` ignores the enclosing context.
    def with(distinct_id: nil, session_id: nil, properties: nil, fresh: false)
      base = fresh ? EMPTY : current
      stack.push(distinct_id: distinct_id || base[:distinct_id], session_id: session_id || base[:session_id],
                 properties: base[:properties].merge(properties || {}))
      yield
    ensure
      stack.pop
    end

    # Reads the browser tracing headers from a header Hash or a Rack env (HTTP_X_LUCIDA_*). NOTE: these headers are
    # client-controlled; never use them for authentication or authorization.
    def from_headers(headers)
      h = (headers || {}).each_with_object({}) { |(k, v), m| m[k.to_s.downcase.tr("_", "-").sub(/\Ahttp-/, "")] = v }
      { distinct_id: clean(h[HEADER_DISTINCT]), session_id: clean(h[HEADER_SESSION]) }
    end

    def clean(value)
      s = value.is_a?(Array) ? value.first.to_s : value.to_s
      s = s.gsub(/[\x00-\x1f\x7f]/, "").strip[0, 1000]
      s.empty? ? nil : s
    end
  end
end
