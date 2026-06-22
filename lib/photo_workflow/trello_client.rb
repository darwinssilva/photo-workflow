require_relative "http_json"
require_relative "settings"

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

    def update_card_position(card_id, pos:)
      HttpJson.put("#{BASE_URL}/cards/#{card_id}", query: auth_params.merge(
        pos: pos
      ))
    end

    def archive_card(card_id)
      HttpJson.put("#{BASE_URL}/cards/#{card_id}", query: auth_params.merge(
        closed: true
      ))
    end

    def delete_card(card_id)
      HttpJson.delete("#{BASE_URL}/cards/#{card_id}", headers: {}, query: auth_params)
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

    def list_cards(list_id)
      HttpJson.get("#{BASE_URL}/lists/#{list_id}/cards", headers: {}, query: auth_params.merge(
        fields: "id,name,desc,due,dueComplete,shortUrl,url,closed,dateLastActivity,pos"
      ))
    end

    def find_active_card_by_name(name, list_id: required_env("TRELLO_LIST_ID"))
      list_cards(list_id)
        .select { |card| !card["closed"] && card["name"] == name }
        .min_by { |card| [card["dateLastActivity"].to_s, card["pos"].to_f] }
    end

    private

    def auth_params
      {
        key: required_env("TRELLO_KEY"),
        token: required_env("TRELLO_TOKEN")
      }
    end

    def required_env(name)
      Settings.required(name)
    end
  end
end
