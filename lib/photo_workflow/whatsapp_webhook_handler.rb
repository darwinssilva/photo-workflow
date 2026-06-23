require "json"

require_relative "settings"

module PhotoWorkflow
  class WhatsAppWebhookHandler
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

      if statuses.empty?
        puts "WhatsApp webhook received without status updates."
        return response(200, "ok")
      end

      statuses.each do |status|
        log_status(status)
      end

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
