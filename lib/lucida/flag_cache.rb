# frozen_string_literal: true

module Lucida
  # Flag definition cache provider: lets many workers share one definitions fetch (Redis, KV, files...).
  # Implement #flag_definitions, #should_fetch_flag_definitions?, #on_flag_definitions_received(defs) and
  # #shutdown; pass `flag_definition_cache:` to Client. A provider that raises means "fetch yourself".
  module FlagCache
    # Reference implementation: process-local, fetches again once ttl seconds have passed.
    class InMemory
      def initialize(ttl: 30.0)
        @ttl = ttl
        @defs = nil
        @at = 0.0
        @mutex = Mutex.new
      end

      def flag_definitions = @mutex.synchronize { @defs }

      def should_fetch_flag_definitions?
        @mutex.synchronize { @defs.nil? || Process.clock_gettime(Process::CLOCK_MONOTONIC) - @at >= @ttl }
      end

      def on_flag_definitions_received(defs)
        @mutex.synchronize do
          @defs = defs
          @at = Process.clock_gettime(Process::CLOCK_MONOTONIC)
        end
      end

      def shutdown = nil
    end

    module_function

    # Definitions to use instead of fetching, or nil when this process must fetch.
    def adopt(provider)
      return nil if provider.nil? || provider.should_fetch_flag_definitions?

      provider.flag_definitions
    rescue StandardError
      nil
    end

    def publish(provider, defs)
      provider&.on_flag_definitions_received(defs)
    rescue StandardError
      nil
    end
  end
end
