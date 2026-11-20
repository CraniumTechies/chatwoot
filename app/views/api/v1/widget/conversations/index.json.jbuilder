if @conversation
  json.id @conversation.display_id
  json.inbox_id @conversation.inbox_id
  json.contact_last_seen_at @conversation.contact_last_seen_at.to_i
  json.status @conversation.status
end

# Expose traveller-visible planning context, never private notes or arbitrary custom attributes.
if @conversation
  json.planning_request @conversation.custom_attributes['planning_request']
  json.contact_last_seen_at @conversation.contact_last_seen_at.to_i
  json.agent_last_seen_at @conversation.agent_last_seen_at&.to_i
  json.coordination do
    json.inbox_name @conversation.inbox.name
    json.assigned @conversation.assignee.present? || @conversation.team.present?
    json.team_name @conversation.team&.name
    if @conversation.assignee.present?
      json.agent do
        json.name @conversation.assignee.available_name
        json.avatar_url @conversation.assignee.avatar_url
      end
    end
  end
  json.capabilities do
    json.preferences true
    json.attachments @web_widget.attachments?
    json.structured_offers false
    json.operator_availability false
  end
end
