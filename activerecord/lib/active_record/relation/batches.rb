# frozen_string_literal: true

require "active_record/relation/batches/batch_enumerator"

module ActiveRecord
  module Batches
    ORDER_IGNORE_MESSAGE = "Scoped order is ignored, it's forced to be batch order."

    # Looping through a collection of records from the database
    # (using the Scoping::Named::ClassMethods.all method, for example)
    # is very inefficient since it will try to instantiate all the objects at once.
    #
    # In that case, batch processing methods allow you to work
    # with the records in batches, thereby greatly reducing memory consumption.
    #
    # The #find_each method uses #find_in_batches with a batch size of 1000 (or as
    # specified by the +:batch_size+ option).
    #
    #   Person.find_each do |person|
    #     person.do_awesome_stuff
    #   end
    #
    #   Person.where("age > 21").find_each do |person|
    #     person.party_all_night!
    #   end
    #
    # If you do not provide a block to #find_each, it will return an Enumerator
    # for chaining with other methods:
    #
    #   Person.find_each.with_index do |person, index|
    #     person.award_trophy(index + 1)
    #   end
    #
    # ==== Options
    # * <tt>:batch_size</tt> - Specifies the size of the batch. Defaults to 1000.
    # * <tt>:start</tt> - Specifies the iteration key value to start from, inclusive of the value.
    # * <tt>:finish</tt> - Specifies the iteration key value to end at, inclusive of the value.
    # * <tt>:error_on_ignore</tt> - Overrides the application config to specify if an error should be raised when
    #   an order is present in the relation.
    # * <tt>:order</tt> - Specifies the iteration key order (can be :asc or :desc). Defaults to :asc.
    # * <tt>:by</tt> - Specifies the iteration key. Defaults to the primary key.
    #
    # Limits are honored, and if present there is no requirement for the batch
    # size: it can be less than, equal to, or greater than the limit.
    #
    # The options +start+ and +finish+ are especially useful if you want
    # multiple workers dealing with the same processing queue. You can make
    # worker 1 handle all the records between id 1 and 9999 and worker 2
    # handle from 10000 and beyond by setting the +:start+ and +:finish+
    # option on each worker.
    #
    #   # In worker 1, let's process until 9999 records.
    #   Person.find_each(finish: 9_999) do |person|
    #     person.party_all_night!
    #   end
    #
    #   # In worker 2, let's process from record 10_000 and onwards.
    #   Person.find_each(start: 10_000) do |person|
    #     person.party_all_night!
    #   end
    #
    # NOTE: Order can be ascending (:asc) or descending (:desc). It is automatically set to
    # ascending on the iteration key (ie "id ASC").
    # This also means that this method only works when the iteration key is
    # orderable (e.g. an integer or string).
    #
    # NOTE: By its nature, batch processing is subject to race conditions if
    # other processes are modifying the database.
    def find_each(start: nil, finish: nil, batch_size: 1000, error_on_ignore: nil, order: :asc, by: primary_key)
      if block_given?
        find_in_batches(start: start, finish: finish, batch_size: batch_size, error_on_ignore: error_on_ignore, order: order, by: by) do |records|
          records.each { |record| yield record }
        end
      else
        enum_for(:find_each, start: start, finish: finish, batch_size: batch_size, error_on_ignore: error_on_ignore, order: order, by: by) do
          relation = self
          apply_limits(relation, by, start, finish, order).size
        end
      end
    end

    # Yields each batch of records that was found by the find options as
    # an array.
    #
    #   Person.where("age > 21").find_in_batches do |group|
    #     sleep(50) # Make sure it doesn't get too crowded in there!
    #     group.each { |person| person.party_all_night! }
    #   end
    #
    # If you do not provide a block to #find_in_batches, it will return an Enumerator
    # for chaining with other methods:
    #
    #   Person.find_in_batches.with_index do |group, batch|
    #     puts "Processing group ##{batch}"
    #     group.each(&:recover_from_last_night!)
    #   end
    #
    # To be yielded each record one by one, use #find_each instead.
    #
    # ==== Options
    # * <tt>:batch_size</tt> - Specifies the size of the batch. Defaults to 1000.
    # * <tt>:start</tt> - Specifies the iteration key value to start from, inclusive of the value.
    # * <tt>:finish</tt> - Specifies the iteration key value to end at, inclusive of the value.
    # * <tt>:error_on_ignore</tt> - Overrides the application config to specify if an error should be raised when
    #   an order is present in the relation.
    # * <tt>:order</tt> - Specifies the iteration key order (can be :asc or :desc). Defaults to :asc.
    # * <tt>:by</tt> - Specifies the iteration key. Defaults to the primary key.
    #
    # Limits are honored, and if present there is no requirement for the batch
    # size: it can be less than, equal to, or greater than the limit.
    #
    # The options +start+ and +finish+ are especially useful if you want
    # multiple workers dealing with the same processing queue. You can make
    # worker 1 handle all the records between id 1 and 9999 and worker 2
    # handle from 10000 and beyond by setting the +:start+ and +:finish+
    # option on each worker.
    #
    #   # Let's process from record 10_000 on.
    #   Person.find_in_batches(start: 10_000) do |group|
    #     group.each { |person| person.party_all_night! }
    #   end
    #
    # NOTE: Order can be ascending (:asc) or descending (:desc). It is automatically set to
    # ascending on the iteration key (ie "id ASC").
    # This also means that this method only works when the iteration key is
    # orderable (e.g. an integer or string).
    #
    # NOTE: By its nature, batch processing is subject to race conditions if
    # other processes are modifying the database.
    def find_in_batches(start: nil, finish: nil, batch_size: 1000, error_on_ignore: nil, order: :asc, by: primary_key)
      relation = self
      unless block_given?
        return to_enum(:find_in_batches, start: start, finish: finish, batch_size: batch_size, error_on_ignore: error_on_ignore, order: order, by: by) do
          total = apply_limits(relation, by, start, finish, order).size
          (total - 1).div(batch_size) + 1
        end
      end

      in_batches(of: batch_size, start: start, finish: finish, load: true, error_on_ignore: error_on_ignore, order: order, by: by) do |batch|
        yield batch.to_a
      end
    end

    # Yields ActiveRecord::Relation objects to work with a batch of records.
    #
    #   Person.where("age > 21").in_batches do |relation|
    #     relation.delete_all
    #     sleep(10) # Throttle the delete queries
    #   end
    #
    # If you do not provide a block to #in_batches, it will return a
    # BatchEnumerator which is enumerable.
    #
    #   Person.in_batches.each_with_index do |relation, batch_index|
    #     puts "Processing relation ##{batch_index}"
    #     relation.delete_all
    #   end
    #
    # Examples of calling methods on the returned BatchEnumerator object:
    #
    #   Person.in_batches.delete_all
    #   Person.in_batches.update_all(awesome: true)
    #   Person.in_batches.each_record(&:party_all_night!)
    #
    # ==== Options
    # * <tt>:of</tt> - Specifies the size of the batch. Defaults to 1000.
    # * <tt>:load</tt> - Specifies if the relation should be loaded. Defaults to false.
    # * <tt>:start</tt> - Specifies the iteration key value to start from, inclusive of the value.
    # * <tt>:finish</tt> - Specifies the iteration key value to end at, inclusive of the value.
    # * <tt>:error_on_ignore</tt> - Overrides the application config to specify if an error should be raised when
    #   an order is present in the relation.
    # * <tt>:order</tt> - Specifies the iteration key order (can be :asc or :desc). Defaults to :asc.
    # * <tt>:by</tt> - Specifies the iteration key. Defaults to the primary key.
    #
    # Limits are honored, and if present there is no requirement for the batch
    # size, it can be less than, equal, or greater than the limit.
    #
    # The options +start+ and +finish+ are especially useful if you want
    # multiple workers dealing with the same processing queue. You can make
    # worker 1 handle all the records between id 1 and 9999 and worker 2
    # handle from 10000 and beyond by setting the +:start+ and +:finish+
    # option on each worker.
    #
    #   # Let's process from record 10_000 on.
    #   Person.in_batches(start: 10_000).update_all(awesome: true)
    #
    # An example of calling where query method on the relation:
    #
    #   Person.in_batches.each do |relation|
    #     relation.update_all('age = age + 1')
    #     relation.where('age > 21').update_all(should_party: true)
    #     relation.where('age <= 21').delete_all
    #   end
    #
    # NOTE: If you are going to iterate through each record, you should call
    # #each_record on the yielded BatchEnumerator:
    #
    #   Person.in_batches.each_record(&:party_all_night!)
    #
    # NOTE: Order can be ascending (:asc) or descending (:desc). It is automatically set to
    # ascending on the iteration key ("id ASC").
    # This also means that this method only works when the iteration key is
    # orderable (e.g. an integer or string).
    #
    # NOTE: By its nature, batch processing is subject to race conditions if
    # other processes are modifying the database.
    def in_batches(of: 1000, start: nil, finish: nil, load: false, error_on_ignore: nil, order: :asc, by: primary_key)
      relation = self
      unless block_given?
        return BatchEnumerator.new(of: of, start: start, finish: finish, by: by, relation: self)
      end

      unless [:asc, :desc].include?(order)
        raise ArgumentError, ":order must be :asc or :desc, got #{order.inspect}"
      end

      if arel.orders.present?
        act_on_ignored_order(error_on_ignore)
      end

      keys = Array(by)
      raise ArgumentError, ":by must be present" if keys.empty?

      start = Array(start)
      raise ArgumentError, "Start length must not exceed by length" if start.length > keys.length

      finish = Array(finish)
      raise ArgumentError, "Finish length must not exceed by length" if finish.length > keys.length

      batch_limit = of
      if limit_value
        remaining   = limit_value
        batch_limit = remaining if remaining < batch_limit
      end

      batch_orders = keys.map do |key|
        batch_order(order, key)
      end

      limit_relation = relation.reorder(*batch_orders).limit(batch_limit)
      limit_relation = apply_finish_limit(limit_relation, keys, finish, order) if !finish.empty?
      limit_relation.skip_query_cache! # Retaining the results in the query cache would undermine the point of batching

      offset = []
      loop do
        batch_relation = limit_relation
        if !offset.empty?
          batch_relation = apply_offset_limit(batch_relation, keys, offset, order)
        elsif !start.empty?
          batch_relation = apply_start_limit(batch_relation, keys, start, order)
        end

        values = if load
          batch_relation.records.map do |record|
            keys.map { |key| record.public_send(key) }
          end
        else
          # Pluck handles n-ary arguments differently from unary arguments
          if keys.many?
            batch_relation.pluck(*keys)
          else
            batch_relation.pluck(*keys).map { |v| [v] }
          end
        end

        break if values.empty?

        yielded_relation = relation

        if !offset.empty?
          yielded_relation = apply_offset_limit(yielded_relation, keys, offset, order)
        elsif !start.empty?
          yielded_relation = apply_start_limit(yielded_relation, keys, start, order)
        end

        offset = values.last
        raise ArgumentError.new("Iteration key not included in the custom select clause") if offset.include?(nil)

        yielded_relation = apply_finish_limit(yielded_relation, keys, offset, order)
        yielded_relation.load_records(batch_relation.records) if load
        yield yielded_relation

        break if values.length < batch_limit

        if limit_value
          remaining -= values.length

          if remaining == 0
            # Saves a useless iteration when the limit is a multiple of the
            # batch size.
            break
          elsif remaining < batch_limit
            limit_relation = limit_relation.limit(remaining)
          end
        end
      end
    end

    private
      def apply_limits(relation, keys, start, finish, order)
        keys = Array(keys)

        start = Array(start)
        relation = apply_start_limit(relation, keys, start, order) if !start.empty?

        finish = Array(finish)
        relation = apply_finish_limit(relation, keys, finish, order) if !finish.empty?

        relation
      end

      def coerce_array(value)
        case value
        when NilClass
          []
        when Array
          value
        else
          [value]
        end
      end

      def apply_start_limit(relation, keys, start, order)
        apply_limit(relation, keys, start, order == :desc ? :lteq : :gteq)
      end

      def apply_finish_limit(relation, keys, finish, order)
        apply_limit(relation, keys, finish, order == :desc ? :gteq : :lteq)
      end

      def apply_offset_limit(relation, keys, offset, order)
        apply_limit(relation, keys, offset, order == :desc ? :lt : :gt)
      end

      def apply_limit(relation, keys, values, operator)
        # Zip retains the length of the first array
        entries = values.zip(keys).reverse
        relation.where(batch_limit(entries, operator))
      end

      # Emulates composite row comparison
      def batch_limit(entries, operator)
        value, key = entries.first

        node = table[key].public_send(operator, value)

        entries = entries.drop(1)

        entries.each do |value, key|
          node = node.and(table[key].eq(value))
        end

        if entries.empty?
          node
        else
          node.or(batch_limit(entries, exclusive(operator)))
        end
      end

      def exclusive(operator)
        case operator
        when :gteq
          :gt
        when :lteq
          :lt
        else
          operator
        end
      end

      def batch_order(order, key)
        table[key].public_send(order)
      end

      def act_on_ignored_order(error_on_ignore)
        raise_error = (error_on_ignore.nil? ? ActiveRecord.error_on_ignored_order : error_on_ignore)

        if raise_error
          raise ArgumentError.new(ORDER_IGNORE_MESSAGE)
        elsif logger
          logger.warn(ORDER_IGNORE_MESSAGE)
        end
      end
  end
end
