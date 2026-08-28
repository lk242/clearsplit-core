import type { SupabaseClient } from 'npm:@supabase/supabase-js@2.112.2'
import type { MessagingProvider, MessagingRepository } from './types.ts'

export function createMessagingRepository(supabase: SupabaseClient): MessagingRepository {
  return {
    async beginEvent(provider, eventId, messageId) {
      const { data, error } = await supabase.rpc('begin_messaging_webhook_event', {
        p_provider: provider,
        p_event_id: eventId,
        p_source_message_id: messageId,
      })
      if (error) throw error
      if (!isRecord(data) || typeof data.shouldProcess !== 'boolean') throw new Error('invalid webhook lease response')
      return data.shouldProcess
    },

    async completeEvent(provider, eventId, success, groupId, errorMessage) {
      const { error } = await supabase.rpc('complete_messaging_webhook_event', {
        p_provider: provider,
        p_event_id: eventId,
        p_success: success,
        p_group_id: groupId,
        p_error: errorMessage ?? null,
      })
      if (error) throw error
    },

    async redeemConversationCode(provider, code, conversationId, userId) {
      const { data, error } = await supabase.rpc('redeem_messaging_bind_code', {
        p_provider: provider,
        p_code: code,
        p_conversation_id: conversationId,
        p_external_user_id: userId,
      })
      if (error) return null
      if (!isRecord(data) || typeof data.groupId !== 'string' || typeof data.groupName !== 'string') return null
      return { groupId: data.groupId, groupName: data.groupName }
    },

    async redeemIdentityCode(provider, code, userId, displayName) {
      const { data, error } = await supabase.rpc('redeem_messaging_identity_code', {
        p_provider: provider,
        p_code: code,
        p_external_user_id: userId,
        p_external_display_name: displayName,
      })
      if (error) return null
      if (!isRecord(data) || typeof data.groupId !== 'string' || typeof data.groupName !== 'string' || typeof data.memberName !== 'string') return null
      return { groupId: data.groupId, groupName: data.groupName, memberName: data.memberName }
    },

    async findConversation(provider, conversationId) {
      const { data, error } = await supabase
        .from('messaging_conversation_bindings')
        .select('group_id')
        .eq('provider', provider)
        .eq('external_conversation_id', conversationId)
        .eq('active', true)
        .maybeSingle()
      if (error) throw error
      return typeof data?.group_id === 'string' ? { groupId: data.group_id } : null
    },

    async findIdentity(provider, groupId, userId) {
      const { data, error } = await supabase
        .from('messaging_identities')
        .select('member_id, members!inner(display_name)')
        .eq('provider', provider)
        .eq('group_id', groupId)
        .eq('external_user_id', userId)
        .maybeSingle()
      if (error) throw error
      const member = normalizeJoinedRecord(data?.members)
      return typeof data?.member_id === 'string' && typeof member?.display_name === 'string'
        ? { memberId: data.member_id, displayName: member.display_name }
        : null
    },

    async createDraft(input) {
      const { data, error } = await supabase
        .from('messaging_fund_expense_drafts')
        .insert({
          provider: input.provider,
          webhook_event_id: input.eventId,
          source_message_id: input.messageId,
          external_conversation_id: input.conversationId,
          external_user_id: input.userId,
          group_id: input.groupId,
          submitted_member_id: input.memberId,
          submitted_display_name: input.displayName,
          raw_text: input.rawText,
          title: input.title,
          amount: input.amount,
          effective_date: input.effectiveDate,
        })
        .select('id, group_id')
        .single()
      if (error) throw error
      if (typeof data?.id !== 'string' || typeof data.group_id !== 'string') throw new Error('invalid messaging draft response')
      return { id: data.id, groupId: data.group_id }
    },

    async cancelDraftByMessage(provider: MessagingProvider, messageId: string) {
      const { data, error } = await supabase
        .from('messaging_fund_expense_drafts')
        .update({ raw_text: null, status: 'cancelled', cancelled_at: new Date().toISOString() })
        .eq('provider', provider)
        .eq('source_message_id', messageId)
        .eq('status', 'pending')
        .select('group_id')
        .maybeSingle()
      if (error) throw error
      return typeof data?.group_id === 'string' ? data.group_id : null
    },
  }
}

function isRecord(value: unknown): value is Record<string, unknown> {
  return typeof value === 'object' && value !== null && !Array.isArray(value)
}

function normalizeJoinedRecord(value: unknown) {
  if (Array.isArray(value)) return isRecord(value[0]) ? value[0] : null
  return isRecord(value) ? value : null
}
