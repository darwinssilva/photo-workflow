require "json"
require "set"

require_relative "settings"
require_relative "whatsapp_client"

module PhotoWorkflow
  class WhatsAppWebhookHandler
    def initialize(whatsapp_client: WhatsAppClient.new)
      @whatsapp_client = whatsapp_client
      @processed_message_ids = Set.new
    end

    def verify(mode:, verify_token:, challenge:)
      return response(400, "missing mode") if blank_string?(mode)
      return response(400, "missing challenge") if blank_string?(challenge)

      expected = Settings.value("WHATSAPP_WEBHOOK_VERIFY_TOKEN", "")
      if !expected.empty? && verify_token != expected
        return response(403, "invalid verify token")
      end

      return response(400, "unsupported mode") unless mode == "subscribe"

      response(200, challenge)
    end

    def receive(body:)
      payload = parse_json(body)
      statuses = extract_statuses(payload)
      messages = extract_messages(payload)

      statuses.each do |status|
        log_status(status)
      end

      messages.each do |message|
        reply_to_message(message)
      end

      puts "WhatsApp webhook received without messages or status updates." if statuses.empty? && messages.empty?
      response(200, "ok")
    rescue JSON::ParserError => error
      warn "WhatsApp webhook invalid JSON: #{error.message}"
      response(400, "invalid json")
    rescue StandardError => error
      warn "WhatsApp webhook failed: #{error.class} - #{error.message}"
      response(500, "error")
    end

    private

    def parse_json(body)
      raw = body.to_s
      return {} if raw.strip.empty?

      JSON.parse(raw)
    end

    def extract_statuses(payload)
      entries = payload.fetch("entry", [])
      return [] unless entries.is_a?(Array)

      entries.flat_map do |entry|
        changes = entry.fetch("changes", [])
        next [] unless changes.is_a?(Array)

        changes.flat_map do |change|
          value = change["value"] || {}
          statuses = value["statuses"] || []
          next [] unless statuses.is_a?(Array)

          statuses.map do |status|
            status.merge("metadata" => value["metadata"] || {})
          end
        end
      end
    end

    def extract_messages(payload)
      entries = payload.fetch("entry", [])
      return [] unless entries.is_a?(Array)

      entries.flat_map do |entry|
        changes = entry.fetch("changes", [])
        next [] unless changes.is_a?(Array)

        changes.flat_map do |change|
          value = change["value"] || {}
          messages = value["messages"] || []
          messages.is_a?(Array) ? messages : []
        end
      end
    end

    def reply_to_message(message)
      return unless Settings.boolean("WHATSAPP_AUTO_REPLY_ENABLED", true)

      message_id = message["id"].to_s
      sender = message["from"].to_s
      return if blank_string?(message_id) || blank_string?(sender)
      return if @processed_message_ids.include?(message_id)

      text = Settings.value(
        "WHATSAPP_AUTO_REPLY_TEXT",
        "Ola! Este numero e utilizado exclusivamente para notificacoes automaticas e nao recebe atendimento por aqui. Para falar conosco, entre em contato pelo telefone (11) 92529-6565."
      )
      @whatsapp_client.send_text_message(to: sender, text: text)
      @processed_message_ids.add(message_id)
    end

    def log_status(status)
      message_id = status["id"] || "unknown"
      recipient_id = status["recipient_id"] || "unknown"
      state = status["status"] || "unknown"
      timestamp = status["timestamp"] || "unknown"
      phone_number_id = status.dig("metadata", "phone_number_id") || "unknown"

      base = "WhatsApp status: state=#{state} message_id=#{message_id} recipient=#{recipient_id} phone_number_id=#{phone_number_id} timestamp=#{timestamp}"

      errors = status["errors"]
      if errors.is_a?(Array) && !errors.empty?
        formatted_errors = errors.map do |error|
          "code=#{error["code"]} title=#{error["title"]} details=#{error["details"]}"
        end.join(" | ")
        warn "#{base} errors=#{formatted_errors}"
      else
        puts base
      end
    end

    def blank_string?(value)
      value.to_s.strip.empty?
    end

    def response(status, body)
      {
        status: status,
        body: body
      }
    end
  end
end
