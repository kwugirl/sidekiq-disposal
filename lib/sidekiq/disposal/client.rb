# frozen_string_literal: true

require "sidekiq"

module Sidekiq
  module Disposal
    # A client for marking enqueued jobs for disposal. Disposal can be a job
    # getting "killed" (sent straight to the dead queue/morgue) or "dropped"
    # (hard deleted entirely).
    #
    # This task is accomplished with "markers": A job can be "marked" for a
    # type of disposal. This means that a "marker" (a job id/jid, batch id/bid,
    # or class name) can be formatted and then added to the relevant target
    # set.
    #
    # When a worker picks up the job, the corresponding `ServerMiddleware` will
    # then ensure that the job is not executed (see that class for more
    # information).
    class Client
      REDIS_KILL_TARGET_SET = "sidekiq-disposal:kill_targets"
      REDIS_DROP_TARGET_SET = "sidekiq-disposal:drop_targets"

      ALLOWED_MARKER_TYPES = [
        :jid,
        :bid,
        :class
      ].freeze

      def initialize(sidekiq_api = ::Sidekiq)
        @sidekiq_api = sidekiq_api
      end

      # @param disposal_method [:kill, :drop] How to handle job
      # @param marker_type [:jid, :bid, :class_name]
      # @param marker [String]
      def mark(disposal_method, marker_type, marker)
        redis do |conn|
          formatted_marker = formatted_marker(marker_type, marker)
          disposal_target_set = disposal_target_set(disposal_method)
          conn.sadd(disposal_target_set, formatted_marker)
        end
      end

      # @param disposal_method [:kill, :drop] How to handle job
      # @param marker_type [:jid, :bid, :class_name]
      # @param marker [String]
      def unmark(disposal_method, marker_type, marker)
        redis do |conn|
          formatted_marker = formatted_marker(marker_type, marker)
          disposal_target_set = disposal_target_set(disposal_method)
          conn.srem(disposal_target_set, formatted_marker)
        end
      end

      def unmark_all(disposal_method)
        redis do |conn|
          conn.del(disposal_target_set(disposal_method))
        end
      end

      def markers(disposal_method)
        redis do |conn|
          conn.smembers(disposal_target_set(disposal_method))
        end
      end

      def kill_target?(job)
        job_in_target_set?(job, disposal_target_set(:kill))
      end

      def drop_target?(job)
        job_in_target_set?(job, disposal_target_set(:drop))
      end

      private

      def redis(&blk)
        sidekiq_api.redis(&blk)
      end

      def disposal_target_set(disposal_method)
        case disposal_method
        when :kill
          REDIS_KILL_TARGET_SET
        when :drop
          REDIS_DROP_TARGET_SET
        else
          raise ArgumentError, "disposal_method must be either :kill or :drop, instead got: #{disposal_method}"
        end
      end

      def job_in_target_set?(job, target_set)
        redis do |conn|
          # `SMISEMBERS setname element1 [element2 ...]` asks whether each
          # element given is in `setname`; redis-client (the low-level redis
          # api used by Sidekiq) returns an array of integer answers for
          # each element: 1 if it's a member, and 0 otherwise.
          conn.smismember(target_set, formatted_markers(job)).any? do |match|
            match == 1
          end
        end
      end

      # @return [Array] A list of identifying formatted_markers/features which
      #                 indicates a job is targeted for disposal.
      def formatted_markers(job)
        ALLOWED_MARKER_TYPES.map do |marker_type|
          formatted_marker_for_job(marker_type, job)
        end.compact
      end

      # @returns the formatted marker that would be in Redis if this job has
      # been targeted
      def formatted_marker_for_job(marker_type, job)
        formatted_marker(marker_type, job[marker_type.to_s])
      end

      # @returns the marker as it is stored in Redis
      def formatted_marker(marker_type, marker)
        return nil if marker.nil?
        raise ArgumentError unless ALLOWED_MARKER_TYPES.include?(marker_type.to_sym)
        "#{marker_type}:#{marker}"
      end

      attr_reader :sidekiq_api
    end
  end
end
