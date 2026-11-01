# frozen_string_literal: true

require "digest"

module Lucida
  # Super properties, person-property setters and identify/group dedupe for Client. Expects the including class
  # to provide #capture and a @mutex.
  module Identity
    DEDUPE_SIZE = 1000

    # Adds properties to every later event; context and per-call properties win.
    def register(properties)
      @mutex.synchronize { super_props.merge!(properties.transform_keys(&:to_s)) }
    end

    def unregister(key)
      @mutex.synchronize { super_props.delete(key.to_s) }
    end

    # `$set` event updating person properties.
    def set_person_properties(distinct_id, properties)
      capture(distinct_id, "$set", set: properties)
    end

    # `$set` event with `$set_once`: only fills properties that are not set yet.
    def set_person_properties_once(distinct_id, properties)
      capture(distinct_id, "$set", set_once: properties)
    end

    private

    def super_props = (@super_props ||= {})

    # True the first time this exact call (kind, id, properties) is seen by the client; bounded LRU.
    def first_identity?(*parts)
      key = Digest::SHA256.hexdigest(JSON.generate(parts))
      @mutex.synchronize do
        seen = (@identities ||= {})
        fresh = !seen.delete(key)
        seen[key] = true
        seen.shift if seen.size > DEDUPE_SIZE
        fresh
      end
    end
  end
end
