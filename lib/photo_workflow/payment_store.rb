require "bigdecimal"
require "date"
require "securerandom"
require "time"

require_relative "settings"
require_relative "state_store"

module PhotoWorkflow
  class PaymentStore
    METHODS = %w[pix dinheiro cartao transferencia outro].freeze

    def initialize(path: Settings.value("PAYMENTS_STATE_PATH", "data/payments.json"))
      @state_store = StateStore.new(path: path)
    end

    def all
      state_store.all.fetch("payments", []).sort_by { |payment| [payment.fetch("date", ""), payment.fetch("client", "")] }.reverse
    end

    def find(id)
      all.find { |payment| payment.fetch("id") == id }
    end

    def create(attributes)
      payment = normalize(attributes).merge(
        "id" => SecureRandom.uuid,
        "created_at" => Time.now.utc.iso8601,
        "updated_at" => Time.now.utc.iso8601
      )

      state_store.with_lock do
        state = normalized_state
        state["payments"] << payment
        state_store.save(state)
      end

      payment
    end

    def update(id, attributes)
      updated_payment = nil

      state_store.with_lock do
        state = normalized_state
        index = state["payments"].index { |payment| payment.fetch("id") == id }
        return nil unless index

        updated_payment = state["payments"][index].merge(normalize(attributes)).merge("updated_at" => Time.now.utc.iso8601)
        state["payments"][index] = updated_payment
        state_store.save(state)
      end

      updated_payment
    end

    def delete(id)
      deleted = false

      state_store.with_lock do
        state = normalized_state
        before_count = state["payments"].size
        state["payments"] = state["payments"].reject { |payment| payment.fetch("id") == id }
        deleted = state["payments"].size != before_count
        state_store.save(state) if deleted
      end

      deleted
    end

    def month_payments(month)
      selected_month = month.to_s
      all.select { |payment| payment.fetch("date", "").start_with?(selected_month) }
    end

    def totals(payments)
      by_method = payments.each_with_object(Hash.new { |hash, key| hash[key] = BigDecimal("0") }) do |payment, totals|
        totals[payment.fetch("method")] += BigDecimal(payment.fetch("amount_cents").to_s) / 100
      end

      total = by_method.values.reduce(BigDecimal("0"), :+)
      average = payments.empty? ? BigDecimal("0") : total / payments.size

      {
        total: total,
        average: average,
        count: payments.size,
        by_method: by_method.sort.to_h
      }
    end

    private

    attr_reader :state_store

    def normalized_state
      state = state_store.all
      state["payments"] ||= []
      state
    end

    def normalize(attributes)
      date = Date.iso8601(attributes.fetch("date").to_s)
      client = attributes.fetch("client").to_s.strip
      amount = parse_amount(attributes.fetch("amount").to_s)
      method = attributes.fetch("method").to_s
      note = attributes.fetch("note", "").to_s.strip

      raise ArgumentError, "Informe o cliente" if client.empty?
      raise ArgumentError, "Informe um valor maior que zero" if amount <= 0
      raise ArgumentError, "Forma de pagamento invalida" unless METHODS.include?(method)

      {
        "date" => date.iso8601,
        "client" => client,
        "amount_cents" => (amount * 100).round.to_i,
        "method" => method,
        "note" => note
      }
    rescue Date::Error
      raise ArgumentError, "Data invalida"
    end

    def parse_amount(value)
      normalized = value.strip.gsub(".", "").tr(",", ".")
      BigDecimal(normalized)
    rescue ArgumentError
      raise ArgumentError, "Valor invalido"
    end
  end
end
