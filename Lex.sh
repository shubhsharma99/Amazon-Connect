
#!/usr/bin/env bash
# create_bot_and_lambda.sh
set -euo pipefail

# ─── CONFIG ────────────────────────────────────────────────────────────────
REGION="ap-southeast-1"
ACCOUNT_ID="253596390115"

LAMBDA_NAME="RetrieveDataLambda"
LAMBDA_ROLE="LambdaLexExecutionRole"

BOT_NAME="SupportBot"
BOT_ROLE="Lex_${BOT_NAME}_Role"
BOT_ALIAS="prod"
INTENT_NAME="CheckOrderStatus"
SLOT_NAME="orderID"

# ─── 1) Lambda Role ─────────────────────────────────────────────────────────
echo "➤ Ensuring IAM role $LAMBDA_ROLE exists …"
if aws iam get-role --role-name "$LAMBDA_ROLE" &>/dev/null; then
  echo "  Role exists, reusing."
else
  aws iam create-role     --role-name "$LAMBDA_ROLE"     --assume-role-policy-document '{
      "Version":"2012-10-17",
      "Statement":[{
        "Effect":"Allow",
        "Principal":{"Service":"lambda.amazonaws.com"},
        "Action":"sts:AssumeRole"}]}' >/dev/null
  aws iam attach-role-policy     --role-name "$LAMBDA_ROLE"     --policy-arn arn:aws:iam::aws:policy/service-role/AWSLambdaBasicExecutionRole
  echo "  Waiting for role propagation…"; sleep 10
fi
LAMBDA_ROLE_ARN=$(aws iam get-role --role-name "$LAMBDA_ROLE"   --query 'Role.Arn' --output text)

# ─── 2) Lambda Function ─────────────────────────────────────────────────────
echo "➤ Deploying Lambda $LAMBDA_NAME …"
mkdir -p tmp_lambda
cat > tmp_lambda/lambda_function.py <<'PY'
def lambda_handler(event, context):
    order_id = (event.get('sessionState', {})
                       .get('intent', {})
                       .get('slots', {})
                       .get('orderID', {})
                       .get('value', {})
                       .get('interpretedValue', 'unknown'))
    return {
        "sessionState": {
            "dialogAction": { "type": "Close" },
            "intent": { "name": event['sessionState']['intent']['name'],
                        "state": "Fulfilled" }
        },
        "messages": [{
            "contentType": "PlainText",
            "content": f"Order #{order_id} is confirmed and will arrive tomorrow."
        }]
    }
PY
(cd tmp_lambda && zip -q ../lambda.zip lambda_function.py)

if aws lambda get-function --function-name "$LAMBDA_NAME" --region "$REGION" &>/dev/null; then
  echo "  Function exists, updating code."
  aws lambda update-function-code     --function-name "$LAMBDA_NAME"     --zip-file fileb://lambda.zip     --region "$REGION" >/dev/null
else
  echo "  Creating function."
  aws lambda create-function     --function-name "$LAMBDA_NAME"     --runtime python3.12     --role "$LAMBDA_ROLE_ARN"     --handler lambda_function.lambda_handler     --zip-file fileb://lambda.zip     --region "$REGION" >/dev/null
fi
LAMBDA_ARN=$(aws lambda get-function --function-name "$LAMBDA_NAME" --region "$REGION"   --query 'Configuration.FunctionArn' --output text)

aws lambda add-permission   --function-name "$LAMBDA_NAME"   --statement-id LexInvokePerm   --action lambda:InvokeFunction   --principal lex.amazonaws.com   --region "$REGION" 2>/dev/null || true

# ─── 3) Lex Bot and Role ────────────────────────────────────────────────────
echo "➤ Ensuring IAM role $BOT_ROLE exists …"
if aws iam get-role --role-name "$BOT_ROLE" &>/dev/null; then
  echo "  Role exists, reusing."
else
  aws iam create-role     --role-name "$BOT_ROLE"     --assume-role-policy-document '{
      "Version":"2012-10-17",
      "Statement":[{
        "Effect":"Allow",
        "Principal":{"Service":"lex.amazonaws.com"},
        "Action":"sts:AssumeRole"}]}' >/dev/null
  aws iam attach-role-policy     --role-name "$BOT_ROLE"     --policy-arn arn:aws:iam::aws:policy/AmazonLexFullAccess
  echo "  Waiting for role propagation…"; sleep 10
fi
BOT_ROLE_ARN=$(aws iam get-role --role-name "$BOT_ROLE" --query 'Role.Arn' --output text)

# ─── 4) Lex Bot ─────────────────────────────────────────────────────────────
echo "➤ Creating or updating Lex bot $BOT_NAME …"
BOT_ID=$(aws lexv2-models list-bots --region "$REGION"   --query "botSummaries[?botName=='$BOT_NAME'].botId" --output text)

if [ -z "$BOT_ID" ]; then
  BOT_ID=$(aws lexv2-models create-bot     --bot-name "$BOT_NAME"     --data-privacy childDirected=false     --idle-session-ttl-in-seconds 300     --role-arn "$BOT_ROLE_ARN"     --region "$REGION"     --query 'botId' --output text)
  echo "  Created bot ID: $BOT_ID"
else
  echo "  Bot exists: $BOT_ID"
fi

# ─── 5) Create locale ───────────────────────────────────────────────────────
aws lexv2-models create-bot-locale \
  --bot-id "$BOT_ID" --bot-version "DRAFT" \
  --locale-id "en_US" \
  --nlu-intent-confidence-threshold 0.4 \
  --region "$REGION" 2>/dev/null || true

# ─── 6) Create intent ───────────────────────────────────────────────────────
# ─── 6) Create or Update Intent ─────────────────────────────────────────────

EXISTING_INTENT_ID=$(aws lexv2-models list-intents \
  --bot-id "$BOT_ID" --bot-version "DRAFT" --locale-id "en_US" \
  --region "$REGION" \
  --query "intentSummaries[?intentName=='$INTENT_NAME'].intentId" --output text)

if [ -n "$EXISTING_INTENT_ID" ]; then
  echo "  Updating existing intent: $INTENT_NAME"

  # Get slot ID for orderID if exists
  ORDER_ID_SLOT_ID=$(aws lexv2-models list-slots \
    --bot-id "$BOT_ID" \
    --bot-version DRAFT \
    --locale-id en_US \
    --intent-id "$EXISTING_INTENT_ID" \
    --region "$REGION" \
    --query "slotSummaries[?slotName=='$SLOT_NAME'].slotId" \
    --output text 2>/dev/null || echo "")

  # Create slot if missing
  if [ -z "$ORDER_ID_SLOT_ID" ] || [[ "$ORDER_ID_SLOT_ID" == "None" ]]; then
    echo "  Creating slot: $SLOT_NAME"
    ORDER_ID_SLOT_ID=$(aws lexv2-models create-slot \
      --bot-id "$BOT_ID" --bot-version DRAFT \
      --locale-id en_US --intent-id "$EXISTING_INTENT_ID" \
      --region "$REGION" \
      --slot-name "$SLOT_NAME" \
      --slot-type-id "AMAZON.Number" \
      --value-elicitation-setting '{
        "slotConstraint": "Required",
        "promptSpecification": {
          "messageGroups": [{
            "message": {
              "plainTextMessage": {
                "value": "Please provide your 6-digit order ID."
              }
            }
          }],
          "maxRetries": 2
        }
      }' \
      --query 'slotId' --output text)
  fi

  # Now update intent with slotPriorities
  aws lexv2-models update-intent \
    --bot-id "$BOT_ID" --bot-version "DRAFT" --locale-id "en_US" \
    --intent-id "$EXISTING_INTENT_ID" --region "$REGION" \
    --cli-input-json "{
      \"intentName\": \"$INTENT_NAME\",
      \"sampleUtterances\": [
        {\"utterance\": \"Track my order\"},
        {\"utterance\": \"Where is my package\"},
        {\"utterance\": \"What is the status of my order\"}
      ],
      \"slotPriorities\": [
        {\"priority\": 1, \"slotId\": \"$ORDER_ID_SLOT_ID\"}
      ],
      \"fulfillmentCodeHook\": { \"enabled\": true },
      \"intentClosingSetting\": {
        \"closingResponse\": {
          \"messageGroups\": [{
            \"message\": {
              \"plainTextMessage\": {
                \"value\": \"Okay, one moment please.\"
              }
            }
          }],
          \"allowInterrupt\": true
        },
        \"active\": true
      }
    }"
  INTENT_ID="$EXISTING_INTENT_ID"

else
  echo "  Creating intent: $INTENT_NAME"
  INTENT_ID=$(aws lexv2-models create-intent \
    --bot-id "$BOT_ID" --bot-version "DRAFT" --locale-id "en_US" \
    --region "$REGION" \
    --cli-input-json "{
      \"intentName\": \"$INTENT_NAME\",
      \"sampleUtterances\": [
        {\"utterance\": \"Track my order\"},
        {\"utterance\": \"Where is my package\"},
        {\"utterance\": \"What is the status of my order\"}
      ],
      \"fulfillmentCodeHook\": { \"enabled\": true },
      \"intentClosingSetting\": {
        \"closingResponse\": {
          \"messageGroups\": [{
            \"message\": {
              \"plainTextMessage\": {
                \"value\": \"Okay, one moment please.\"
              }
            }
          }],
          \"allowInterrupt\": true
        },
        \"active\": true
      }
    }" --query 'intentId' --output text)

  # Create slot immediately after intent creation
  ORDER_ID_SLOT_ID=$(aws lexv2-models create-slot \
    --bot-id "$BOT_ID" --bot-version DRAFT \
    --locale-id en_US --intent-id "$INTENT_ID" \
    --region "$REGION" \
    --slot-name "$SLOT_NAME" \
    --slot-type-id "AMAZON.Number" \
    --value-elicitation-setting '{
      "slotConstraint": "Required",
      "promptSpecification": {
        "messageGroups": [{
          "message": {
            "plainTextMessage": {
              "value": "Please provide your 6-digit order ID."
            }
          }
        }],
        "maxRetries": 2
      }
    }' --query 'slotId' --output text)

  # Add slotPriorities after slot creation
  aws lexv2-models update-intent \
    --bot-id "$BOT_ID" --bot-version "DRAFT" --locale-id "en_US" \
    --intent-id "$INTENT_ID" --region "$REGION" \
    --cli-input-json "{
      \"intentName\": \"$INTENT_NAME\",
      \"sampleUtterances\": [
        {\"utterance\": \"Track my order\"},
        {\"utterance\": \"Where is my package\"},
        {\"utterance\": \"What is the status of my order\"}
      ],
      \"slotPriorities\": [
        {\"priority\": 1, \"slotId\": \"$ORDER_ID_SLOT_ID\"}
      ],
      \"fulfillmentCodeHook\": { \"enabled\": true },
      \"intentClosingSetting\": {
        \"closingResponse\": {
          \"messageGroups\": [{
            \"message\": {
              \"plainTextMessage\": {
                \"value\": \"Okay, one moment please.\"
              }
            }
          }],
          \"allowInterrupt\": true
        },
        \"active\": true
      }
    }"
fi


# ─── 8) Build locale again ──────────────────────────────────────────────────
aws lexv2-models build-bot-locale \
  --bot-id "$BOT_ID" --bot-version "DRAFT" \
  --locale-id "en_US" --region "$REGION" >/dev/null
aws lexv2-models wait bot-locale-built \
  --bot-id "$BOT_ID" --bot-version "DRAFT" \
  --locale-id "en_US" --region "$REGION"

# ─── 9) Create alias ────────────────────────────────────────────────────────
ALIAS_ID=$(aws lexv2-models create-bot-alias   --bot-alias-name "$BOT_ALIAS"   --bot-id "$BOT_ID"   --bot-version "DRAFT"   --region "$REGION"   --query 'botAliasId' --output text 2>/dev/null ||   aws lexv2-models list-bot-aliases --bot-id "$BOT_ID"     --region "$REGION"     --query "botAliasSummaries[?botAliasName=='$BOT_ALIAS'].botAliasId" --output text)

BOT_ALIAS_ARN="arn:aws:lex:${REGION}:${ACCOUNT_ID}:bot-alias/${ALIAS_ID}/bot/${BOT_ID}/${BOT_ALIAS}"

# ─── 10) Done ───────────────────────────────────────────────────────────────
echo -e "\n✅ Bot & Lambda setup complete!"
echo "Lambda ARN:        $LAMBDA_ARN"
echo "Lex Bot ID:        $BOT_ID"
echo "Bot Alias ARN:     $BOT_ALIAS_ARN"
echo -e "\nPaste this Bot Alias ARN into Amazon Connect → Get customer input block."
