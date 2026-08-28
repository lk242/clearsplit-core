-- Server-side reconciliation is authoritative and operates on one PostgreSQL
-- statement snapshot. Portable exports intentionally exclude LINE user IDs,
-- invite tokens, auth user IDs, and raw LINE messages.

insert into public.app_schema_versions (version, name)
values (30, 'ledger reconciliation and portable backup');

create function public.get_ledger_reconciliation(p_group_id uuid)
returns jsonb
language plpgsql
stable
security definer
set search_path = public
as $$
declare
  invalid_private_share_count bigint;
  invalid_private_status_count bigint;
  invalid_fund_transaction_count bigint;
  private_expense_count bigint;
  open_private_obligation_count bigint;
  fund_configured boolean;
  fund_balance bigint := 0;
  fund_account_total bigint := 0;
  fund_balance_difference bigint := 0;
  open_advance_count bigint;
  open_collection_count bigint;
  pending_line_draft_count bigint;
begin
  if (select auth.uid()) is null or not public.is_group_member(p_group_id) then
    raise exception 'ledger access denied' using errcode = '42501';
  end if;

  select count(*) into private_expense_count
  from public.expenses where group_id = p_group_id;

  select count(*) into invalid_private_share_count
  from public.expenses expense
  left join lateral (
    select count(*) as share_count, coalesce(sum(share.amount), 0) as share_total
    from public.expense_shares share
    where share.expense_id = expense.id
  ) shares on true
  where expense.group_id = p_group_id
    and (shares.share_count = 0 or shares.share_total <> expense.amount);

  with expense_state as (
    select expense.id, expense.status,
      count(*) filter (
        where share.member_id <> expense.payer_member_id
          and share.amount > 0
          and not coalesce((
            receipt.amount = share.amount
            and receipt.paid_at is not null
            and receipt.received_at is not null
          ), false)
      ) as open_count
    from public.expenses expense
    left join public.expense_shares share on share.expense_id = expense.id
    left join public.expense_receipts receipt
      on receipt.expense_id = share.expense_id
      and receipt.debtor_member_id = share.member_id
    where expense.group_id = p_group_id
    group by expense.id, expense.status
  )
  select
    count(*) filter (where (status = 'resolved') <> (open_count = 0)),
    coalesce(sum(open_count), 0)
  into invalid_private_status_count, open_private_obligation_count
  from expense_state;

  select exists (
    select 1 from public.group_funds where group_id = p_group_id
  ) into fund_configured;

  if fund_configured then
    select balance into fund_balance
    from public.group_funds where group_id = p_group_id;
    select coalesce(sum(balance), 0) into fund_account_total
    from public.fund_member_accounts where group_id = p_group_id;
    fund_balance_difference := fund_balance - fund_account_total;
  end if;

  select count(*) into invalid_fund_transaction_count
  from public.fund_transactions transaction
  left join lateral (
    select coalesce(sum(line.amount_delta), 0) as line_total
    from public.fund_transaction_lines line
    where line.transaction_id = transaction.id
  ) lines on true
  where transaction.group_id = p_group_id
    and lines.line_total <> transaction.amount_delta;

  select count(*) into open_advance_count
  from public.fund_advances where group_id = p_group_id and status = 'open';
  select count(*) into open_collection_count
  from public.fund_collection_rounds where group_id = p_group_id and status = 'open';
  select count(*) into pending_line_draft_count
  from public.line_fund_expense_drafts where group_id = p_group_id and status = 'pending';

  return jsonb_build_object(
    'checkedAt', now(),
    'isHealthy', invalid_private_share_count = 0
      and invalid_private_status_count = 0
      and invalid_fund_transaction_count = 0
      and fund_balance_difference = 0,
    'privateExpenseCount', private_expense_count,
    'invalidPrivateShareCount', invalid_private_share_count,
    'invalidPrivateStatusCount', invalid_private_status_count,
    'openPrivateObligationCount', open_private_obligation_count,
    'fundConfigured', fund_configured,
    'fundBalance', fund_balance,
    'fundAccountTotal', fund_account_total,
    'fundBalanceDifference', fund_balance_difference,
    'invalidFundTransactionCount', invalid_fund_transaction_count,
    'openAdvanceCount', open_advance_count,
    'openCollectionCount', open_collection_count,
    'pendingLineDraftCount', pending_line_draft_count
  );
end;
$$;

create function public.export_ledger_backup(p_group_id uuid)
returns jsonb
language plpgsql
stable
security definer
set search_path = public
as $$
declare
  group_record public.ledger_groups;
  fund_record public.group_funds;
  public_fund jsonb := null;
begin
  if (select auth.uid()) is null or not public.is_group_owner(p_group_id) then
    raise exception 'responsible member permission required' using errcode = '42501';
  end if;
  select * into group_record from public.ledger_groups where id = p_group_id;
  if not found then raise exception 'ledger is unavailable' using errcode = '22023'; end if;

  select * into fund_record from public.group_funds where group_id = p_group_id;
  if found then
    public_fund := jsonb_build_object(
      'cycleNumber', fund_record.cycle_number,
      'status', fund_record.status,
      'balance', fund_record.balance,
      'configuredAt', fund_record.configured_at,
      'closingStartedAt', fund_record.closing_started_at,
      'closedAt', fund_record.closed_at,
      'accounts', coalesce((
        select jsonb_agg(jsonb_build_object(
          'memberId', account.member_id,
          'memberName', member.display_name,
          'balance', account.balance,
          'contributedTotal', account.contributed_total,
          'consumedTotal', account.consumed_total,
          'refundedTotal', account.refunded_total
        ) order by member.created_at, member.id)
        from public.fund_member_accounts account
        join public.members member on member.id = account.member_id and member.group_id = account.group_id
        where account.group_id = p_group_id
      ), '[]'::jsonb),
      'transactions', coalesce((
        select jsonb_agg(jsonb_build_object(
          'id', transaction.id,
          'cycleNumber', transaction.cycle_number,
          'type', transaction.transaction_type,
          'title', transaction.title,
          'amountDelta', transaction.amount_delta,
          'balanceAfter', transaction.balance_after,
          'effectiveDate', transaction.effective_date,
          'note', transaction.note,
          'createdAt', transaction.created_at,
          'lines', coalesce((
            select jsonb_agg(jsonb_build_object(
              'memberId', line.member_id,
              'memberName', member.display_name,
              'amountDelta', line.amount_delta
            ) order by member.created_at, member.id)
            from public.fund_transaction_lines line
            join public.members member on member.id = line.member_id and member.group_id = line.group_id
            where line.transaction_id = transaction.id
          ), '[]'::jsonb)
        ) order by transaction.effective_date, transaction.created_at)
        from public.fund_transactions transaction
        where transaction.group_id = p_group_id
      ), '[]'::jsonb),
      'advances', coalesce((
        select jsonb_agg(jsonb_build_object(
          'id', advance.id,
          'transactionId', advance.transaction_id,
          'memberId', advance.member_id,
          'memberName', member.display_name,
          'amount', advance.amount,
          'status', advance.status,
          'memberConfirmedAt', advance.member_confirmed_at,
          'responsibleConfirmedAt', advance.responsible_confirmed_at,
          'completedAt', advance.completed_at,
          'createdAt', advance.created_at
        ) order by advance.created_at)
        from public.fund_advances advance
        join public.members member on member.id = advance.member_id and member.group_id = advance.group_id
        where advance.group_id = p_group_id
      ), '[]'::jsonb),
      'collections', coalesce((
        select jsonb_agg(jsonb_build_object(
          'id', round.id,
          'cycleNumber', round.cycle_number,
          'title', round.title,
          'amountPerMember', round.amount_per_member,
          'effectiveDate', round.effective_date,
          'status', round.status,
          'createdAt', round.created_at,
          'completedAt', round.completed_at,
          'entries', coalesce((
            select jsonb_agg(jsonb_build_object(
              'memberId', entry.member_id,
              'memberName', member.display_name,
              'amount', entry.amount,
              'status', entry.status,
              'memberConfirmedAt', entry.member_confirmed_at,
              'responsibleConfirmedAt', entry.responsible_confirmed_at,
              'completedAt', entry.completed_at
            ) order by member.created_at, member.id)
            from public.fund_collection_entries entry
            join public.members member on member.id = entry.member_id and member.group_id = entry.group_id
            where entry.round_id = round.id
          ), '[]'::jsonb)
        ) order by round.effective_date, round.created_at)
        from public.fund_collection_rounds round
        where round.group_id = p_group_id
      ), '[]'::jsonb)
    );
  end if;

  return jsonb_build_object(
    'format', 'clearsplit-ledger-backup-v1',
    'schemaVersion', (select max(version) from public.app_schema_versions),
    'exportedAt', now(),
    'ledger', jsonb_build_object('id', group_record.id, 'name', group_record.name),
    'reconciliation', public.get_ledger_reconciliation(p_group_id),
    'members', coalesce((
      select jsonb_agg(jsonb_build_object(
        'id', member.id,
        'name', member.display_name,
        'color', member.color,
        'avatarUrl', member.avatar_url,
        'isResponsible', member.id = group_record.responsible_member_id,
        'createdAt', member.created_at
      ) order by member.created_at, member.id)
      from public.members member where member.group_id = p_group_id
    ), '[]'::jsonb),
    'privateExpenses', coalesce((
      select jsonb_agg(jsonb_build_object(
        'id', expense.id,
        'title', expense.title,
        'amount', expense.amount,
        'category', expense.category,
        'payerMemberId', expense.payer_member_id,
        'payerName', payer.display_name,
        'splitMode', expense.split_mode,
        'status', expense.status,
        'resolvedAt', expense.resolved_at,
        'date', expense.expense_date,
        'note', expense.note,
        'version', expense.version,
        'createdAt', expense.created_at,
        'shares', coalesce((
          select jsonb_agg(jsonb_build_object(
            'memberId', share.member_id,
            'memberName', member.display_name,
            'amount', share.amount,
            'paidAt', receipt.paid_at,
            'receivedAt', receipt.received_at,
            'completedAt', receipt.completed_at
          ) order by share.share_order)
          from public.expense_shares share
          join public.members member on member.id = share.member_id and member.group_id = share.group_id
          left join public.expense_receipts receipt
            on receipt.expense_id = share.expense_id and receipt.debtor_member_id = share.member_id
          where share.expense_id = expense.id
        ), '[]'::jsonb)
      ) order by expense.expense_date, expense.created_at)
      from public.expenses expense
      join public.members payer on payer.id = expense.payer_member_id and payer.group_id = expense.group_id
      where expense.group_id = p_group_id
    ), '[]'::jsonb),
    'publicFund', public_fund,
    'pendingLineFundDrafts', coalesce((
      select jsonb_agg(jsonb_build_object(
        'id', draft.id,
        'title', draft.title,
        'amount', draft.amount,
        'effectiveDate', draft.effective_date,
        'submittedMemberId', draft.submitted_member_id,
        'submittedDisplayName', draft.submitted_display_name,
        'createdAt', draft.created_at
      ) order by draft.created_at)
      from public.line_fund_expense_drafts draft
      where draft.group_id = p_group_id and draft.status = 'pending'
    ), '[]'::jsonb),
    'auditTrail', coalesce((
      select jsonb_agg(jsonb_build_object(
        'id', event.id,
        'entityType', event.entity_type,
        'entityId', event.entity_id,
        'action', event.action,
        'createdAt', event.created_at
      ) order by event.created_at, event.id)
      from public.audit_events event where event.group_id = p_group_id
    ), '[]'::jsonb)
  );
end;
$$;

revoke all on function public.get_ledger_reconciliation(uuid) from public, anon;
grant execute on function public.get_ledger_reconciliation(uuid) to authenticated;
revoke all on function public.export_ledger_backup(uuid) from public, anon;
grant execute on function public.export_ledger_backup(uuid) to authenticated;
