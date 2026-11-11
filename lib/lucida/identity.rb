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

    # The uuid to send an identify/group event under the first time this exact call (kind, id, properties) is seen
    # by the client (bounded LRU), else nil. #release_identities frees it again when the event is dropped.
    def identity_uuid(*parts)
      key = Digest::SHA256.hexdigest(JSON.generate(parts))
      @mutex.synchronize do
        seen = (@identities ||= {})
        fresh = !seen.delete(key)
        seen[key] = true
        seen.shift if seen.size > DEDUPE_SIZE
        next nil unless fresh

        uuid = Wire.uuid7
        keys = (@identity_keys ||= {})
        keys[uuid] = key
        keys.shift if keys.size > DEDUPE_SIZE
        uuid
      end
    end

    # Forget the calls whose events were dropped (rejected batch, full queue) so repeating them is sent again.
    def release_identities(events)
      @mutex.synchronize do
        events.each do |e|
          key = @identity_keys&.delete(e["uuid"])
          @identities&.delete(key) if key
        end
      end
    end
  end
end
