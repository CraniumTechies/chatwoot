class Api::V1::Widget::ConversationsController < Api::V1::Widget::BaseController
  include Events::Types
  before_action :render_not_found_if_empty, only: [:toggle_typing, :toggle_status, :set_custom_attributes, :destroy_custom_attributes, :update_planning_preferences]

  def index
    @conversation = conversation
  end

  def create
    ActiveRecord::Base.transaction do
      process_update_contact
      @conversation = create_conversation
      conversation.messages.create!(message_params)
      # TODO: Temporary fix for message type cast issue, since message_type is returning as string instead of integer
      conversation.reload
    end
  end

  def process_update_contact
    @contact = ContactIdentifyAction.new(
      contact: @contact,
      params: { email: contact_email, phone_number: contact_phone_number, name: contact_name },
      retain_original_contact_name: true,
      discard_invalid_attrs: true
    ).perform
  end

  def update_last_seen
    head :ok && return if conversation.nil?

    conversation.contact_last_seen_at = DateTime.now.utc
    conversation.save!
    ::Conversations::UpdateMessageStatusJob.perform_later(conversation.id, conversation.contact_last_seen_at)
    head :ok
  end

  def transcript
    if conversation.present? && conversation.contact.present? && conversation.contact.email.present?
      ConversationReplyMailer.with(account: conversation.account).conversation_transcript(
        conversation,
        conversation.contact.email
      )&.deliver_later
    end
    head :ok
  end

  def toggle_typing
    case permitted_params[:typing_status]
    when 'on'
      trigger_typing_event(CONVERSATION_TYPING_ON)
    when 'off'
      trigger_typing_event(CONVERSATION_TYPING_OFF)
    end

    head :ok
  end

  def toggle_status
    return head :forbidden unless @web_widget.end_conversation?

    unless conversation.resolved?
      conversation.status = :resolved
      conversation.save!
    end
    head :ok
  end

  def set_custom_attributes
    conversation.update!(custom_attributes: permitted_params[:custom_attributes])
  end

  def destroy_custom_attributes
    conversation.custom_attributes = conversation.custom_attributes.excluding(params[:custom_attribute])
    conversation.save!
    render json: conversation
  end

  # Planning preferences are not availability, an offer or a booking confirmation.
  def update_planning_preferences
    values = params.permit(:revision, :start_date, :end_date, :adults, :children, :notes)
    adults = Integer(values[:adults], exception: false)
    children = Integer(values[:children], exception: false)
    start_date = Date.iso8601(values[:start_date].to_s) if values[:start_date].present?
    end_date = Date.iso8601(values[:end_date].to_s) if values[:end_date].present?
    invalid = adults.nil? || children.nil? || adults < 1 || adults > 100 || children.negative? || children > 100
    invalid ||= start_date.present? != end_date.present? || (start_date && end_date && end_date < start_date)
    return render json: { error: 'Invalid planning preferences' }, status: :unprocessable_entity if invalid

    conversation.with_lock do
      planning = conversation.custom_attributes['planning_request']
      return head :not_found unless planning.is_a?(Hash)
      return head :conflict unless Integer(values[:revision], exception: false) == planning.fetch('revision', 1)

      updated = planning.merge('revision' => planning.fetch('revision', 1) + 1,
                               'dates' => { 'start' => start_date&.iso8601, 'end' => end_date&.iso8601 },
                               'party' => { 'adults' => adults, 'children' => children }, 'notes' => values[:notes].to_s.first(2000))
      conversation.update!(custom_attributes: conversation.custom_attributes.merge('planning_request' => updated))
      conversation.messages.create!(account_id: conversation.account_id, inbox_id: conversation.inbox_id, sender: @contact,
                                    message_type: :incoming, content: 'Trip preferences updated',
                                    content_attributes: { planning_event: { type: 'preferences_updated', revision: updated['revision'] } })
      render json: { planning_request: updated }
    end
  rescue Date::Error
    render json: { error: 'Invalid travel dates' }, status: :unprocessable_entity
  end

  private

  def trigger_typing_event(event)
    Rails.configuration.dispatcher.dispatch(event, Time.zone.now, conversation: conversation, user: @contact)
  end

  def render_not_found_if_empty
    return head :not_found if conversation.nil?
  end

  def permitted_params
    params.permit(:id, :typing_status, :website_token, :email, contact: [:name, :email, :phone_number],
                                                               message: [:content, :referer_url, :timestamp, :echo_id],
                                                               custom_attributes: {})
  end
end
