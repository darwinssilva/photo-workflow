require_relative "http_json"

module PhotoWorkflow
  class TrelloClient
    BASE_URL = "https://api.trello.com/1"

    def create_card(name:, desc:, due:)
      HttpJson.post("#{BASE_URL}/cards", query: auth_params.merge(
        idList: required_env("TRELLO_LIST_ID"),
        name: name,
        desc: desc,
        due: due&.iso8601
      ))
    end

    def update_card(card_id, name:, desc:, due:)
      HttpJson.put("#{BASE_URL}/cards/#{card_id}", query: auth_params.merge(
        name: name,
        desc: desc,
        due: due&.iso8601
      ))
    end

    def archive_card(card_id)
      HttpJson.put("#{BASE_URL}/cards/#{card_id}", query: auth_params.merge(
        closed: true
      ))
    end

    def active_card?(card_id)
      card = get_card(card_id)
      !card["closed"]
    rescue HttpJson::Error => error
      return false if error.code == 404

      raise
    end

    def get_card(card_id)
      HttpJson.get("#{BASE_URL}/cards/#{card_id}", headers: {}, query: auth_params)
    end

    private

    def auth_params
      {
        key: required_env("TRELLO_KEY"),
        token: required_env("TRELLO_TOKEN")
      }
    end

    def required_env(name)
      ENV.fetch(name) { raise "Missing ENV #{name}" }
    end
  end
end
