# normalize-usage.jq — normalize Codex, Claude Code, and Cursor CLI usage into
# a single schema without double-counting cached input tokens or fabricating
# missing fields.
#
# Invocation examples:
#   jq -n --arg provider codex --arg model_requested "gpt-5.6-sol" --argjson raw "$usage" -f normalize-usage.jq
#   jq -s --arg provider claude --arg model_requested "haiku" -f normalize-usage.jq events.jsonl

def opt_str:
  if . == null or . == "" or . == "none" then null else tostring end;

def num_or_null:
  if type == "number" then . else null end;

def sum_or_null(s):
  [s | select(type == "number")] | if length == 0 then null else add end;

(($ARGS.named.provider // "unknown") | ascii_downcase) as $provider
| (($ARGS.named.model_requested // null) | opt_str) as $model_req
| (($ARGS.named.prev_cost // null) | num_or_null) as $prev_cost
| (if ($ARGS.named | has("raw")) then $ARGS.named.raw else . end) as $in
| (
    if $provider == "codex" then
      # Codex: $in can be an array of events from events.jsonl, a turn.completed event, or a raw .usage object.
      (
        if ($in | type) == "array" then
          [ $in[] | select(type == "object")
            | if .type == "turn.completed" and (.usage | type) == "object" then .usage
              elif (.type == null) and (has("input_tokens") or has("output_tokens")) then .
              else empty end
          ]
        elif ($in | type) == "object" then
          if ($in.usage | type) == "object" then [$in.usage]
          elif ($in | has("input_tokens") or has("output_tokens")) then [$in]
          else [] end
        else [] end
      ) as $turns
      | (if ($turns | length) == 0 then null
         else {
           input_tokens: sum_or_null($turns[].input_tokens),
           cached_input_tokens: sum_or_null($turns[].cached_input_tokens),
           cache_write_input_tokens: sum_or_null($turns[].cache_write_input_tokens),
           output_tokens: sum_or_null($turns[].output_tokens),
           reasoning_output_tokens: sum_or_null($turns[].reasoning_output_tokens),
           total_tokens: sum_or_null($turns[].total_tokens),
           cost_usd: sum_or_null($turns[].cost_usd // $turns[].total_cost_usd),
           model_resolved: (
             if ($in | type) == "array" then
               ([ $in[] | select(type == "object") | (.model // .model_id // empty) ] | last // null)
             elif ($in | type) == "object" then ($in.model // $in.model_id // null)
             else null end
           )
         } end)
      | if . == null then
          {
            model_resolved: null,
            input_uncached: null, cache_read: null, cache_write: null,
            output: null, reasoning: null, reported_total: null,
            cost_usd: null, cost_kind: null
          }
        else
          (.input_tokens | num_or_null) as $raw_in
          | (.cached_input_tokens | num_or_null) as $cache_r
          | (.cache_write_input_tokens | num_or_null) as $cache_w
          | (.output_tokens | num_or_null) as $out
          | (.reasoning_output_tokens | num_or_null) as $reas
          | (
              if $raw_in == null then null
              elif $cache_r != null then
                (if $raw_in >= $cache_r then ($raw_in - $cache_r) else $raw_in end)
              else $raw_in end
            ) as $uncached
          | (.cost_usd | num_or_null) as $cost
          | {
              model_resolved: (.model_resolved | opt_str),
              input_uncached: $uncached,
              cache_read: $cache_r,
              cache_write: $cache_w,
              output: $out,
              reasoning: $reas,
              reported_total: (.total_tokens | num_or_null),
              cost_usd: $cost,
              cost_kind: (if $cost != null then "provider_reported" else null end)
            }
        end

    elif $provider == "claude" then
      # Claude: result.usage is per-invocation total; assistant messages are per-step (and may repeat per message.id).
      # Note: result.modelUsage and result.total_cost_usd are session-cumulative across --resume.
      (
        if ($in | type) == "array" then
          ([ $in[] | select(type == "object" and .type == "result") ] | last) as $res
          | ([ $in[] | select(type == "object" and .type == "system" and .subtype == "init") | .model // empty ] | last) as $init_model
          | if $res != null then
              $res + { _init_model: $init_model }
            else
              # Fallback if stream was interrupted before result: deduplicate assistant messages by message.id
              ([ $in[] | select(type == "object" and .type == "assistant" and (.message.usage | type) == "object")
                 | { id: (.message.id // .uuid // "unknown"), model: .message.model, usage: .message.usage }
               ] | unique_by(.id)) as $msgs
              | if ($msgs | length) == 0 then null
                else {
                  usage: {
                    input_tokens: sum_or_null($msgs[].usage.input_tokens),
                    cache_read_input_tokens: sum_or_null($msgs[].usage.cache_read_input_tokens),
                    cache_creation_input_tokens: sum_or_null($msgs[].usage.cache_creation_input_tokens),
                    output_tokens: sum_or_null($msgs[].usage.output_tokens),
                    output_tokens_details: {
                      thinking_tokens: sum_or_null($msgs[].usage.output_tokens_details.thinking_tokens)
                    }
                  },
                  model: ($msgs | last | .model),
                  _init_model: $init_model
                } end
            end
        elif ($in | type) == "object" then
          $in
        else null end
      ) as $obj
      | if $obj == null then
          {
            model_resolved: null,
            input_uncached: null, cache_read: null, cache_write: null,
            output: null, reasoning: null, reported_total: null,
            cost_usd: null, cost_kind: null
          }
        else
          (if ($obj.usage | type) == "object" then $obj.usage else $obj end) as $u
          | ($u.input_tokens | num_or_null) as $uncached
          | ($u.cache_read_input_tokens | num_or_null) as $cache_r
          | ($u.cache_creation_input_tokens | num_or_null) as $cache_w
          | ($u.output_tokens | num_or_null) as $out
          | (($u.output_tokens_details.thinking_tokens // null) | num_or_null) as $reas
          | (($obj.total_cost_usd // $u.total_cost_usd // $obj.cost_usd // null) | num_or_null) as $raw_cost
          | (
              if $raw_cost == null then null
              elif ($prev_cost != null and $prev_cost > 0 and $raw_cost >= $prev_cost) then
                (($raw_cost - $prev_cost) * 1000000000000 | round / 1000000000000)
              else $raw_cost end
            ) as $cost
          | (
              if ($obj.modelUsage | type) == "object" and (($obj.modelUsage | keys | length) > 0) then
                ($obj.modelUsage | to_entries[0] | .value.canonicalModel // .key)
              else
                ($obj.model // $obj._init_model // null)
              end
            ) as $resolved_model
          | (
              if $cost == null then null
              elif ($obj.modelUsage | type) == "object" and (($obj.modelUsage | to_entries[0]?.value.costBasis) == "list") then
                "api_equivalent_estimate"
              else
                "provider_reported"
              end
            ) as $ckind
          | {
              model_resolved: ($resolved_model | opt_str),
              input_uncached: $uncached,
              cache_read: $cache_r,
              cache_write: $cache_w,
              output: $out,
              reasoning: $reas,
              reported_total: ($u.total_tokens | num_or_null),
              cost_usd: $cost,
              cost_kind: $ckind
            }
        end

    elif $provider == "cursor" then
      (
        if ($in | type) == "array" then
          ([ $in[] | select(type == "object") | select(.usage != null or .inputTokens != null or .input_tokens != null or .type == "result") ] | last)
        elif ($in | type) == "object" then $in
        else null end
      ) as $obj
      | if $obj == null then
          {
            model_resolved: null,
            input_uncached: null, cache_read: null, cache_write: null,
            output: null, reasoning: null, reported_total: null,
            cost_usd: null, cost_kind: null
          }
        else
          (if ($obj.usage | type) == "object" then $obj.usage else $obj end) as $u
          | (($u.inputTokens // $u.input_tokens // null) | num_or_null) as $uncached
          | (($u.cacheReadTokens // $u.cache_read_tokens // null) | num_or_null) as $cache_r
          | (($u.cacheWriteTokens // $u.cache_write_tokens // null) | num_or_null) as $cache_w
          | (($u.outputTokens // $u.output_tokens // null) | num_or_null) as $out
          | (($u.reasoningTokens // $u.thinkingTokens // null) | num_or_null) as $reas
          | (($obj.cost_usd // $obj.costUsd // $u.cost_usd // $u.costUsd // null) | num_or_null) as $cost
          | {
              model_resolved: (($obj.model // $u.model // null) | opt_str),
              input_uncached: $uncached,
              cache_read: $cache_r,
              cache_write: $cache_w,
              output: $out,
              reasoning: $reas,
              reported_total: (($u.totalTokens // $u.total_tokens // null) | num_or_null),
              cost_usd: $cost,
              cost_kind: (if $cost != null then "provider_reported" else null end)
            }
        end

    else
      {
        model_resolved: null,
        input_uncached: null, cache_read: null, cache_write: null,
        output: null, reasoning: null, reported_total: null,
        cost_usd: null, cost_kind: null
      }
    end
  ) as $norm
| (
    if ($norm.input_uncached != null and $norm.output != null) then
      ($norm.input_uncached + ($norm.cache_read // 0) + ($norm.cache_write // 0) + $norm.output)
    elif $norm.reported_total != null then
      $norm.reported_total
    else
      null
    end
  ) as $total
| (
    if ($norm.input_uncached != null or $norm.cache_read != null or $norm.cache_write != null or $norm.output != null or $total != null or $norm.cost_usd != null) then
      "cli_result"
    else
      null
    end
  ) as $src
| {
    schema_version: 1,
    model_requested: $model_req,
    model_resolved: $norm.model_resolved,
    input_uncached_tokens: $norm.input_uncached,
    input_tokens: $norm.input_uncached,
    cache_read_tokens: $norm.cache_read,
    cache_write_tokens: $norm.cache_write,
    output_tokens: $norm.output,
    reasoning_tokens: $norm.reasoning,
    total_tokens: $total,
    cost_usd: $norm.cost_usd,
    cost_kind: $norm.cost_kind,
    source: $src
  }
