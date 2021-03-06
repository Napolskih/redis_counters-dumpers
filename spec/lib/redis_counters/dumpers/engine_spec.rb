require 'spec_helper'

describe RedisCounters::Dumpers::Engine do
  let(:dumper) do
    RedisCounters::Dumpers::Engine.build do
      name :stats_totals
      fields record_id: :integer,
             column_id: :integer,
             value: :integer,
             date: :date,
             subject: [:enum, {name: :subject_types}],
             params: :hstore

      destination do
        model StatsByDay
        take :record_id, :column_id, :hits, :date, :params
        key_fields :record_id, :column_id, :date, :params
        increment_fields :hits
        map :hits, to: :value
        condition 'target.date = :date'
      end

      destination do
        model StatsTotal
        take :record_id, :column_id, :hits, :params
        key_fields :record_id, :column_id, :params
        increment_fields :hits
        map :hits, to: :value
      end

      destination do
        model StatsAggTotal
        take :record_id, :hits
        key_fields :record_id
        increment_fields :hits
        map :hits, to: 'sum(value)'
        group_by :record_id
      end

      on_before_merge do |dumper, _connection|
        dumper.common_params = {date: dumper.args[:date].strftime('%Y-%m-%d')}
      end
    end
  end

  let(:prev_date) { Date.new(2015, 1, 19) }
  let(:prev_date_s) { prev_date.strftime('%Y-%m-%d') }

  let(:date) { Date.new(2015, 1, 20) }
  let(:date_s) { date.strftime('%Y-%m-%d') }

  let(:counter) do
    RedisCounters.create_counter(Redis.current,
      counter_class: RedisCounters::HashCounter,
      counter_name: :record_hits_by_day,
      group_keys: [:record_id, :column_id, :subject, :params],
      partition_keys: [:date]
    )
  end

  before do
    allow(dumper).to receive(:redis_session).and_return(MockRedis.new)
  end

  describe '#process!' do
    context 'when increment_fields specified' do
      before do
        counter.increment(date: prev_date_s, record_id: 1, column_id: 100, subject: '', params: '')
        counter.increment(date: prev_date_s, record_id: 1, column_id: 200, subject: '', params: '')
        counter.increment(date: prev_date_s, record_id: 1, column_id: 200, subject: '', params: '')
        counter.increment(date: prev_date_s, record_id: 2, column_id: 100, subject: nil, params: '')

        params = {a: 1}.stringify_keys.to_s[1..-2]
        counter.increment(date: prev_date_s, record_id: 3, column_id: 300, subject: nil, params: params)

        dumper.process!(counter, date: prev_date)

        counter.increment(date: date_s, record_id: 1, column_id: 100, subject: '', params: '')
        counter.increment(date: date_s, record_id: 1, column_id: 200, subject: '', params: '')
        counter.increment(date: date_s, record_id: 1, column_id: 200, subject: '', params: '')
        counter.increment(date: date_s, record_id: 2, column_id: 100, subject: nil, params: '')

        dumper.process!(counter, date: date)
      end

      it { expect(StatsByDay.count).to eq 7 }
      it { expect(StatsByDay.where(record_id: 1, column_id: 100, date: prev_date).first.hits).to eq 1 }
      it { expect(StatsByDay.where(record_id: 1, column_id: 200, date: prev_date).first.hits).to eq 2 }
      it { expect(StatsByDay.where(record_id: 2, column_id: 100, date: prev_date).first.hits).to eq 1 }
      it { expect(StatsByDay.where(record_id: 3, column_id: 300, date: prev_date).first.params).to eq("a" => "1") }
      it { expect(StatsByDay.where(record_id: 1, column_id: 100, date: date).first.hits).to eq 1 }
      it { expect(StatsByDay.where(record_id: 1, column_id: 200, date: date).first.hits).to eq 2 }
      it { expect(StatsByDay.where(record_id: 2, column_id: 100, date: date).first.hits).to eq 1 }

      it { expect(StatsTotal.count).to eq 4 }
      it { expect(StatsTotal.where(record_id: 1, column_id: 100).first.hits).to eq 2 }
      it { expect(StatsTotal.where(record_id: 1, column_id: 200).first.hits).to eq 4 }
      it { expect(StatsTotal.where(record_id: 2, column_id: 100).first.hits).to eq 2 }

      it { expect(StatsAggTotal.count).to eq 3 }
      it { expect(StatsAggTotal.where(record_id: 1).first.hits).to eq 6 }
      it { expect(StatsAggTotal.where(record_id: 2).first.hits).to eq 2 }

      context 'with source conditions' do
        let(:dumper) do
          RedisCounters::Dumpers::Engine.build do
            name :stats_totals
            fields record_id: :integer,
                   column_id: :integer,
                   value: :integer,
                   date: :date

            destination do
              model StatsByDay
              take :record_id, :column_id, :hits, :date
              key_fields :record_id, :column_id, :date
              increment_fields :hits
              map :hits, to: :value
              condition 'target.date = :date'
              source_condition 'column_id = 100'
            end

            destination do
              model StatsTotal
              take :record_id, :column_id, :hits
              key_fields :record_id, :column_id
              increment_fields :hits
              map :hits, to: :value
              source_condition 'column_id = 100'
            end

            destination do
              model StatsAggTotal
              take :record_id, :hits
              key_fields :record_id
              increment_fields :hits
              map :hits, to: 'sum(value)'
              group_by :record_id
              source_condition 'column_id = 100'
            end

            on_before_merge do |dumper, _connection|
              dumper.common_params = {date: dumper.args[:date].strftime('%Y-%m-%d')}
            end
          end
        end

        it { expect(StatsByDay.count).to eq 4 }
        it { expect(StatsByDay.where(record_id: 1, column_id: 100, date: prev_date).first.hits).to eq 1 }
        it { expect(StatsByDay.where(record_id: 2, column_id: 100, date: prev_date).first.hits).to eq 1 }
        it { expect(StatsByDay.where(record_id: 1, column_id: 100, date: date).first.hits).to eq 1 }
        it { expect(StatsByDay.where(record_id: 2, column_id: 100, date: date).first.hits).to eq 1 }

        it { expect(StatsTotal.count).to eq 2 }
        it { expect(StatsTotal.where(record_id: 1, column_id: 100).first.hits).to eq 2 }
        it { expect(StatsTotal.where(record_id: 2, column_id: 100).first.hits).to eq 2 }

        it { expect(StatsAggTotal.count).to eq 2 }
        it { expect(StatsAggTotal.where(record_id: 1).first.hits).to eq 2 }
        it { expect(StatsAggTotal.where(record_id: 2).first.hits).to eq 2 }
      end
    end

    context 'when increment_fields not specified' do
      let(:dumper) do
        RedisCounters::Dumpers::Engine.build do
          name :stats
          fields record_id: :integer,
                 entity_type: :string,
                 date: :timestamp,
                 params: :hstore

          destination do
            model Stat
            take :record_id, :entity_type, :date, :params
            key_fields :record_id, :entity_type, :date, :params
          end

          on_before_merge do |dumper, _connection|
            dumper.common_params = {entity_type: dumper.args[:entity_type]}
          end
        end
      end

      let(:counter) do
        RedisCounters.create_counter(
          Redis.current,
          counter_class: RedisCounters::HashCounter,
          counter_name: :all_stats,
          value_delimiter: ';',
          group_keys: [:date, :record_id, :params],
          partition_keys: [:entity_type]
        )
      end

      let(:date) { Time.now.utc }

      before do
        counter.increment(entity_type: 'Type1', date: date, record_id: 1, params: '')
        counter.increment(entity_type: 'Type2', date: date, record_id: 1, params: '')
        counter.increment(entity_type: 'Type1', date: date - 1.minute, record_id: 1, params: '')
        counter.increment(entity_type: 'Type1', date: date - 10.minutes, record_id: 1, params: '')
        counter.increment(entity_type: 'Type1', date: date, record_id: 2, params: '')

        params = {a: 1}.stringify_keys.to_s[1..-2]
        counter.increment(entity_type: 'Type1', date: date, record_id: 3, params: params)

        dumper.process!(counter, entity_type: 'Type1')
        dumper.process!(counter, entity_type: 'Type2')
      end

      it { expect(Stat.count).to eq 6 }
      it { expect(Stat.where(entity_type: 'Type1').count).to eq 5 }
      it { expect(Stat.where(entity_type: 'Type2').count).to eq 1 }
      it { expect(Stat.where(record_id: 3, entity_type: 'Type1').first.params).to eq("a" => "1") }
    end

    context 'matching_expr is specified' do
      let(:dumper) do
        RedisCounters::Dumpers::Engine.build do
          name :nullable_stats

          fields date: :date,
                 value: :integer,
                 payload: :string

          destination do
            model NullableStat
            take :date, :value, :payload
            key_fields :date, :value, :payload
            increment_fields :value
            condition 'target.date = :date'
            matching_expr <<-EXPR
              (source.date, coalesce(source.payload, '')) =
                (target.date, coalesce(target.payload, ''))
            EXPR
          end

          on_before_merge do |dumper, _|
            dumper.common_params = {date: dumper.args[:date].strftime('%Y-%m-%d')}
          end
        end
      end

      let(:counter) do
        RedisCounters.create_counter(
          Redis.current,
          counter_class: RedisCounters::HashCounter,
          counter_name: :nullable_stats,
          group_keys: [:payload],
          partition_keys: [:date]
        )
      end

      before do
        counter.increment(date: date_s, value: 1, payload: 'foobar')
        counter.increment(date: date_s, value: 1, payload: nil)

        dumper.process!(counter, date: date)
        counter.delete_all!

        counter.increment(date: date_s, value: 1, payload: 'foobar')
        counter.increment(date: date_s, value: 1, payload: nil)

        dumper.process!(counter, date: date)
        counter.delete_all!
      end

      it 'treats nulls as equal to each other because they are coalesced to an empty string' do
        expect(NullableStat.count).to eq(2)
        expect(NullableStat.find_by_payload('foobar').value).to eq(2)
        expect(NullableStat.find_by_payload(nil).value).to eq(2)
      end
    end
  end
end
