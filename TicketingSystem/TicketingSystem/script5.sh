#!/bin/bash
# ============================================================
#  IT Support Ticketing System — AWS Automation Script 5
#  Resources: S3 · DynamoDB · Lambda · API Gateway · SQS · SNS · Cognito
#  Author: Elijah Duran
# ============================================================
# S3 Website URL: (printed at end of script after deployment)
# Test username : student1
# Test password : AhN354o5GMbSTh!
# ============================================================

set -e

# ── Configuration ─────────────────────────────────────────────
REGION="us-east-1"
PROJECT_NAME="IT Support Ticketing System"
BUCKET_NAME="it-support-ticketing-$(date +%s)"
TABLE_NAME="ITSupportDeployments"
TICKETS_TABLE="ITSupportTickets"
SUBMIT_LAMBDA_NAME="itsupport-submit"
PROCESSOR_LAMBDA_NAME="itsupport-processor"
LAMBDA_ROLE_NAME="LabRole"
API_NAME="itsupport-api"
STAGE_NAME="prod"
MAIN_QUEUE_NAME="itsupport-queue"
DLQ_NAME="itsupport-dlq"
SNS_TOPIC_NAME="itsupport-notifications"
COGNITO_POOL_NAME="itsupport-users-pool"
COGNITO_CLIENT_NAME="itsupport-web-client"
USERNAME="student1"
PASSWORD='AhN354o5GMbSTh!'
GROUP1="Admins"
GROUP2="Students"

# ── Temp directory (works on Windows Git Bash and Linux) ──────
# Use the folder where this script lives so paths always resolve
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TMPDIR="$SCRIPT_DIR"

# ── Helpers ───────────────────────────────────────────────────
GREEN='\033[0;32m'; RED='\033[0;31m'; YELLOW='\033[1;33m'; CYAN='\033[0;36m'; BOLD='\033[1m'; NC='\033[0m'
ok()   { echo -e "${GREEN}[✓]${NC} $1"; }
fail() { echo -e "${RED}[✗]${NC} $1"; exit 1; }
info() { echo -e "${CYAN}[→]${NC} $1"; }
warn() { echo -e "${YELLOW}[!]${NC} $1"; }
step() { echo -e "\n${BOLD}${CYAN}============================================================${NC}"; echo -e "${BOLD}${CYAN}  $1${NC}"; echo -e "${BOLD}${CYAN}============================================================${NC}"; }

echo ""
echo -e "${BOLD}${CYAN}============================================================${NC}"
echo -e "${BOLD}${CYAN}   IT Support Ticketing System — AWS Deployment Script 5${NC}"
echo -e "${BOLD}${CYAN}   Includes: S3 · DynamoDB · Lambda · API GW · SQS · SNS · Cognito${NC}"
echo -e "${BOLD}${CYAN}============================================================${NC}"
echo ""

# ── Prompt for SNS email (not hardcoded) ──────────────────────
read -rp "Enter your email address for SNS notifications: " SNS_EMAIL
[[ -z "$SNS_EMAIL" ]] && fail "Email is required for SNS notifications."
ok "SNS email set to: $SNS_EMAIL"

# ── 1. Verify AWS credentials ──────────────────────────────────
step "Step 1: Verify AWS Identity"
info "Verifying AWS credentials..."
aws sts get-caller-identity --region "$REGION"
ACCOUNT_ID=$(aws sts get-caller-identity --query "Account" --output text) || fail "AWS CLI not configured."
IDENTITY=$(aws sts get-caller-identity --query "Arn" --output text)
ok "Authenticated as: $IDENTITY"
ok "Account ID: $ACCOUNT_ID"

# ── 2. IAM Role (LabRole — AWS Academy) ───────────────────────
step "Step 2: IAM Role"
info "Looking up LabRole (AWS Academy environment)..."
ROLE_ARN=$(aws iam get-role --role-name "$LAMBDA_ROLE_NAME" --query "Role.Arn" --output text 2>/dev/null || echo "NOT_FOUND")
[ "$ROLE_ARN" = "NOT_FOUND" ] && fail "LabRole not found. Refresh your AWS Academy credentials."
ok "Using LabRole: $ROLE_ARN"

# ── 3. SQS Dead-Letter Queue ──────────────────────────────────
step "Step 3: SQS Dead-Letter Queue"
info "Creating dead-letter queue: $DLQ_NAME ..."
DLQ_URL=$(aws sqs create-queue \
  --queue-name "$DLQ_NAME" \
  --region "$REGION" \
  --query 'QueueUrl' --output text)
DLQ_ARN=$(aws sqs get-queue-attributes \
  --queue-url "$DLQ_URL" \
  --attribute-names QueueArn \
  --region "$REGION" \
  --query 'Attributes.QueueArn' --output text)
ok "Dead-letter queue created: $DLQ_URL"

# ── 4. SQS Main Queue ─────────────────────────────────────────
step "Step 4: SQS Main Queue"
info "Creating main queue: $MAIN_QUEUE_NAME ..."
MAIN_QUEUE_URL=$(aws sqs create-queue \
  --queue-name "$MAIN_QUEUE_NAME" \
  --region "$REGION" \
  --query 'QueueUrl' --output text)
MAIN_QUEUE_ARN=$(aws sqs get-queue-attributes \
  --queue-url "$MAIN_QUEUE_URL" \
  --attribute-names QueueArn \
  --region "$REGION" \
  --query 'Attributes.QueueArn' --output text)
ok "Main queue created: $MAIN_QUEUE_URL"

info "Connecting main queue to dead-letter queue..."
aws sqs set-queue-attributes \
  --queue-url "$MAIN_QUEUE_URL" \
  --attributes "{\"RedrivePolicy\":\"{\\\"deadLetterTargetArn\\\":\\\"$DLQ_ARN\\\",\\\"maxReceiveCount\\\":\\\"3\\\"}\"}" \
  --region "$REGION"
ok "Redrive policy set (maxReceiveCount=3)"

# ── 5. SNS Topic ──────────────────────────────────────────────
step "Step 5: SNS Topic"
info "Creating SNS topic: $SNS_TOPIC_NAME ..."
SNS_TOPIC_ARN=$(aws sns create-topic \
  --name "$SNS_TOPIC_NAME" \
  --region "$REGION" \
  --query 'TopicArn' --output text)
ok "SNS topic created: $SNS_TOPIC_ARN"

info "Subscribing $SNS_EMAIL to SNS topic..."
aws sns subscribe \
  --topic-arn "$SNS_TOPIC_ARN" \
  --protocol email \
  --notification-endpoint "$SNS_EMAIL" \
  --region "$REGION" > /dev/null
ok "Subscription request sent to $SNS_EMAIL"
warn "ACTION REQUIRED: Check $SNS_EMAIL and click 'Confirm subscription' before testing."

# ── 6. S3 Bucket ──────────────────────────────────────────────
step "Step 6: S3 Static Website"
info "Creating S3 bucket: $BUCKET_NAME ..."
aws s3api create-bucket \
  --bucket "$BUCKET_NAME" \
  --region "$REGION" \
  --output json > /dev/null || fail "Failed to create S3 bucket"
ok "Bucket created: $BUCKET_NAME"

info "Disabling Block Public Access..."
aws s3api put-public-access-block \
  --bucket "$BUCKET_NAME" \
  --public-access-block-configuration "BlockPublicAcls=false,IgnorePublicAcls=false,BlockPublicPolicy=false,RestrictPublicBuckets=false"
ok "Public access unblocked"

info "Enabling static website hosting..."
aws s3 website "s3://$BUCKET_NAME" --index-document index.html --error-document index.html
ok "Static hosting enabled"

info "Applying public-read bucket policy..."
aws s3api put-bucket-policy --bucket "$BUCKET_NAME" --policy '{
  "Version":"2012-10-17",
  "Statement":[{"Sid":"PublicRead","Effect":"Allow","Principal":"*","Action":"s3:GetObject","Resource":"arn:aws:s3:::'"$BUCKET_NAME"'/*"}]
}'
ok "Bucket policy applied"
S3_WEBSITE_URL="http://$BUCKET_NAME.s3-website-$REGION.amazonaws.com"

# ── 7. DynamoDB Tables ────────────────────────────────────────
step "Step 7: DynamoDB Tables"

info "Checking deployment table: $TABLE_NAME ..."
TABLE_EXISTS=$(aws dynamodb describe-table --table-name "$TABLE_NAME" --region "$REGION" \
  --query "Table.TableStatus" --output text 2>/dev/null || echo "NOT_FOUND")
if [ "$TABLE_EXISTS" = "NOT_FOUND" ]; then
  aws dynamodb create-table \
    --table-name "$TABLE_NAME" \
    --attribute-definitions AttributeName=ProjectName,AttributeType=S \
    --key-schema AttributeName=ProjectName,KeyType=HASH \
    --billing-mode PAY_PER_REQUEST \
    --region "$REGION" --output text > /dev/null
  aws dynamodb wait table-exists --table-name "$TABLE_NAME" --region "$REGION"
  ok "Deployment table created: $TABLE_NAME"
else
  ok "Deployment table already exists: $TABLE_NAME"
fi

info "Checking tickets table: $TICKETS_TABLE ..."
TKT_EXISTS=$(aws dynamodb describe-table --table-name "$TICKETS_TABLE" --region "$REGION" \
  --query "Table.TableStatus" --output text 2>/dev/null || echo "NOT_FOUND")
if [ "$TKT_EXISTS" = "NOT_FOUND" ]; then
  aws dynamodb create-table \
    --table-name "$TICKETS_TABLE" \
    --attribute-definitions AttributeName=ticketId,AttributeType=S \
    --key-schema AttributeName=ticketId,KeyType=HASH \
    --billing-mode PAY_PER_REQUEST \
    --region "$REGION" --output text > /dev/null
  aws dynamodb wait table-exists --table-name "$TICKETS_TABLE" --region "$REGION"
  ok "Tickets table created: $TICKETS_TABLE"
else
  ok "Tickets table already exists: $TICKETS_TABLE"
fi

# ── 8. Submit Lambda ──────────────────────────────────────────
step "Step 8: Submit Lambda"
info "Packaging Submit Lambda..."
cat > $TMPDIR/submit_lambda.py << 'PYEOF'
import json, boto3, os, uuid
from datetime import datetime

sqs = boto3.client('sqs')
QUEUE_URL = os.environ.get('SQS_QUEUE_URL', '')

def lambda_handler(event, context):
    headers = {
        'Access-Control-Allow-Origin': '*',
        'Access-Control-Allow-Headers': 'Content-Type,Authorization',
        'Access-Control-Allow-Methods': 'POST,OPTIONS'
    }
    method = event.get('requestContext', {}).get('http', {}).get('method', '')
    if method == 'OPTIONS':
        return {'statusCode': 200, 'headers': headers, 'body': ''}
    try:
        body = json.loads(event.get('body', '{}'))
        body['ticketId']  = 'INC-' + str(uuid.uuid4())[:8].upper()
        body['timestamp'] = datetime.utcnow().isoformat()
        body['status']    = 'open'
        sqs.send_message(QueueUrl=QUEUE_URL, MessageBody=json.dumps(body))
        return {
            'statusCode': 200,
            'headers': headers,
            'body': json.dumps({'message': 'Ticket submitted successfully!', 'ticketId': body['ticketId']})
        }
    except Exception as e:
        return {'statusCode': 500, 'headers': headers, 'body': json.dumps({'error': str(e)})}
PYEOF

# Convert path for PowerShell and AWS CLI (Windows needs backslash paths)
WIN_SUBMIT_PY="$(cygpath -w "$TMPDIR/submit_lambda.py" 2>/dev/null || echo "$TMPDIR/submit_lambda.py")"
WIN_SUBMIT_ZIP="$(cygpath -w "$TMPDIR/submit_lambda.zip" 2>/dev/null || echo "$TMPDIR/submit_lambda.zip")"
rm -f "$TMPDIR/submit_lambda.zip"
powershell.exe -NoProfile -Command "Compress-Archive -Path '$WIN_SUBMIT_PY' -DestinationPath '$WIN_SUBMIT_ZIP' -Force" \
  || fail "Failed to package Submit Lambda zip"
ok "Submit Lambda packaged"

# AWS CLI fileb:// needs forward-slash Windows path: fileb://C:/Users/...
SUBMIT_ZIP_REF="fileb://$(cygpath -m "$TMPDIR/submit_lambda.zip" 2>/dev/null || echo "$TMPDIR/submit_lambda.zip")"

info "Deploying Submit Lambda: $SUBMIT_LAMBDA_NAME ..."
SUBMIT_EXISTS=$(aws lambda get-function --function-name "$SUBMIT_LAMBDA_NAME" --region "$REGION" \
  --query "Configuration.FunctionName" --output text 2>/dev/null || echo "NOT_FOUND")

if [ "$SUBMIT_EXISTS" = "NOT_FOUND" ]; then
  SUBMIT_LAMBDA_ARN=$(aws lambda create-function \
    --function-name "$SUBMIT_LAMBDA_NAME" \
    --runtime python3.12 \
    --role "$ROLE_ARN" \
    --handler submit_lambda.lambda_handler \
    --zip-file "$SUBMIT_ZIP_REF" \
    --environment "Variables={SQS_QUEUE_URL=$MAIN_QUEUE_URL}" \
    --region "$REGION" \
    --query "FunctionArn" --output text)
  aws lambda wait function-active --function-name "$SUBMIT_LAMBDA_NAME" --region "$REGION"
  ok "Submit Lambda created: $SUBMIT_LAMBDA_ARN"
else
  aws lambda update-function-code \
    --function-name "$SUBMIT_LAMBDA_NAME" \
    --zip-file "$SUBMIT_ZIP_REF" \
    --region "$REGION" --output text > /dev/null
  aws lambda wait function-updated \
    --function-name "$SUBMIT_LAMBDA_NAME" --region "$REGION"
  aws lambda update-function-configuration \
    --function-name "$SUBMIT_LAMBDA_NAME" \
    --environment "Variables={SQS_QUEUE_URL=$MAIN_QUEUE_URL}" \
    --region "$REGION" --output text > /dev/null
  aws lambda wait function-updated \
    --function-name "$SUBMIT_LAMBDA_NAME" --region "$REGION"
  SUBMIT_LAMBDA_ARN=$(aws lambda get-function --function-name "$SUBMIT_LAMBDA_NAME" \
    --region "$REGION" --query "Configuration.FunctionArn" --output text)
  ok "Submit Lambda updated: $SUBMIT_LAMBDA_ARN"
fi

# ── 9. Processor Lambda ───────────────────────────────────────
step "Step 9: Processor Lambda"
info "Packaging Processor Lambda..."
cat > $TMPDIR/processor_lambda.py << 'PYEOF'
import json, boto3, os
from datetime import datetime

dynamodb = boto3.resource('dynamodb')
sns      = boto3.client('sns')
TABLE_NAME    = os.environ.get('DYNAMODB_TABLE', '')
SNS_TOPIC_ARN = os.environ.get('SNS_TOPIC_ARN', '')

def lambda_handler(event, context):
    table = dynamodb.Table(TABLE_NAME)
    for record in event.get('Records', []):
        body      = json.loads(record['body'])
        ticket_id = body.get('ticketId', 'unknown')
        table.put_item(Item={
            'ticketId':    ticket_id,
            'requester':   body.get('requester', 'Unknown'),
            'email':       body.get('email', ''),
            'category':    body.get('category', 'Unknown'),
            'priority':    body.get('priority', 'medium'),
            'title':       body.get('title', ''),
            'description': body.get('description', ''),
            'status':      'open',
            'timestamp':   body.get('timestamp', datetime.utcnow().isoformat()),
            'submittedBy': body.get('submittedBy', 'unknown')
        })
        sns.publish(
            TopicArn=SNS_TOPIC_ARN,
            Subject=f"New IT Support Ticket: {ticket_id}",
            Message=(
                f"A new support ticket has been submitted.\n\n"
                f"Ticket ID : {ticket_id}\n"
                f"Requester : {body.get('requester','Unknown')} ({body.get('email','')})\n"
                f"Category  : {body.get('category','Unknown')}\n"
                f"Priority  : {body.get('priority','medium').upper()}\n"
                f"Title     : {body.get('title','')}\n\n"
                f"Description:\n{body.get('description','')}\n\n"
                f"Submitted : {body.get('timestamp','')}"
            )
        )
    return {'statusCode': 200, 'body': 'Processed successfully'}
PYEOF

# Convert path for PowerShell and AWS CLI
WIN_PROC_PY="$(cygpath -w "$TMPDIR/processor_lambda.py" 2>/dev/null || echo "$TMPDIR/processor_lambda.py")"
WIN_PROC_ZIP="$(cygpath -w "$TMPDIR/processor_lambda.zip" 2>/dev/null || echo "$TMPDIR/processor_lambda.zip")"
rm -f "$TMPDIR/processor_lambda.zip"
powershell.exe -NoProfile -Command "Compress-Archive -Path '$WIN_PROC_PY' -DestinationPath '$WIN_PROC_ZIP' -Force" \
  || fail "Failed to package Processor Lambda zip"
ok "Processor Lambda packaged"

PROC_ZIP_REF="fileb://$(cygpath -m "$TMPDIR/processor_lambda.zip" 2>/dev/null || echo "$TMPDIR/processor_lambda.zip")"

info "Deploying Processor Lambda: $PROCESSOR_LAMBDA_NAME ..."
PROC_EXISTS=$(aws lambda get-function --function-name "$PROCESSOR_LAMBDA_NAME" --region "$REGION" \
  --query "Configuration.FunctionName" --output text 2>/dev/null || echo "NOT_FOUND")

if [ "$PROC_EXISTS" = "NOT_FOUND" ]; then
  PROCESSOR_LAMBDA_ARN=$(aws lambda create-function \
    --function-name "$PROCESSOR_LAMBDA_NAME" \
    --runtime python3.12 \
    --role "$ROLE_ARN" \
    --handler processor_lambda.lambda_handler \
    --zip-file "$PROC_ZIP_REF" \
    --environment "Variables={DYNAMODB_TABLE=$TICKETS_TABLE,SNS_TOPIC_ARN=$SNS_TOPIC_ARN}" \
    --region "$REGION" \
    --query "FunctionArn" --output text)
  aws lambda wait function-active --function-name "$PROCESSOR_LAMBDA_NAME" --region "$REGION"
  ok "Processor Lambda created: $PROCESSOR_LAMBDA_ARN"
else
  aws lambda update-function-code \
    --function-name "$PROCESSOR_LAMBDA_NAME" \
    --zip-file "$PROC_ZIP_REF" \
    --region "$REGION" --output text > /dev/null
  aws lambda wait function-updated \
    --function-name "$PROCESSOR_LAMBDA_NAME" --region "$REGION"
  aws lambda update-function-configuration \
    --function-name "$PROCESSOR_LAMBDA_NAME" \
    --environment "Variables={DYNAMODB_TABLE=$TICKETS_TABLE,SNS_TOPIC_ARN=$SNS_TOPIC_ARN}" \
    --region "$REGION" --output text > /dev/null
  aws lambda wait function-updated \
    --function-name "$PROCESSOR_LAMBDA_NAME" --region "$REGION"
  PROCESSOR_LAMBDA_ARN=$(aws lambda get-function --function-name "$PROCESSOR_LAMBDA_NAME" \
    --region "$REGION" --query "Configuration.FunctionArn" --output text)
  ok "Processor Lambda updated: $PROCESSOR_LAMBDA_ARN"
fi

# ── 10. SQS Event Source Mapping ──────────────────────────────
step "Step 10: SQS Event Source Mapping"
info "Wiring SQS → Processor Lambda..."
MAPPING_EXISTS=$(aws lambda list-event-source-mappings \
  --function-name "$PROCESSOR_LAMBDA_NAME" \
  --region "$REGION" \
  --query "EventSourceMappings[?EventSourceArn=='$MAIN_QUEUE_ARN'].UUID" \
  --output text 2>/dev/null)

if [[ -z "$MAPPING_EXISTS" ]]; then
  aws lambda create-event-source-mapping \
    --function-name "$PROCESSOR_LAMBDA_NAME" \
    --event-source-arn "$MAIN_QUEUE_ARN" \
    --batch-size 1 \
    --region "$REGION" --output text > /dev/null
  ok "SQS trigger created for Processor Lambda"
else
  ok "SQS trigger already exists: $MAPPING_EXISTS"
fi

# ── 11. API Gateway ───────────────────────────────────────────
step "Step 11: API Gateway HTTP API"
info "Creating API Gateway HTTP API: $API_NAME ..."
API_ID=$(aws apigatewayv2 create-api \
  --name "$API_NAME" \
  --protocol-type HTTP \
  --cors-configuration AllowOrigins='["*"]',AllowMethods='["POST","OPTIONS"]',AllowHeaders='["Content-Type","Authorization"]' \
  --region "$REGION" \
  --query "ApiId" --output text)
ok "API Gateway created: $API_ID"

info "Creating Lambda integration..."
INTEGRATION_ID=$(aws apigatewayv2 create-integration \
  --api-id "$API_ID" \
  --integration-type AWS_PROXY \
  --integration-uri "$SUBMIT_LAMBDA_ARN" \
  --payload-format-version "2.0" \
  --region "$REGION" \
  --query "IntegrationId" --output text)
ok "Integration created: $INTEGRATION_ID"

info "Creating API route: POST /submit ..."
aws apigatewayv2 create-route \
  --api-id "$API_ID" \
  --route-key "POST /submit" \
  --target "integrations/$INTEGRATION_ID" \
  --region "$REGION" --output text > /dev/null
ok "Route created: POST /submit"

info "Deploying stage: $STAGE_NAME ..."
aws apigatewayv2 create-stage \
  --api-id "$API_ID" \
  --stage-name "$STAGE_NAME" \
  --auto-deploy \
  --region "$REGION" --output text > /dev/null
ok "Stage '$STAGE_NAME' deployed"

API_ENDPOINT="https://$API_ID.execute-api.$REGION.amazonaws.com/$STAGE_NAME"
ok "API Endpoint: $API_ENDPOINT"

info "Granting API Gateway permission to invoke Submit Lambda..."
aws lambda add-permission \
  --function-name "$SUBMIT_LAMBDA_NAME" \
  --statement-id "AllowAPIGateway-$(date +%s)" \
  --action "lambda:InvokeFunction" \
  --principal "apigateway.amazonaws.com" \
  --source-arn "arn:aws:execute-api:$REGION:$ACCOUNT_ID:$API_ID/*/*" \
  --region "$REGION" --output text > /dev/null
ok "Lambda invoke permission granted"

# ── 12. Amazon Cognito ────────────────────────────────────────
step "Step 12: Amazon Cognito"

# --- Create User Pool ---
info "Creating User Pool: $COGNITO_POOL_NAME ..."
USER_POOL_ID=$(aws cognito-idp create-user-pool \
  --pool-name "$COGNITO_POOL_NAME" \
  --region "$REGION" \
  --policies '{
    "PasswordPolicy":{
      "MinimumLength":8,
      "RequireUppercase":true,
      "RequireLowercase":true,
      "RequireNumbers":true,
      "RequireSymbols":true
    }
  }' \
  --query 'UserPool.Id' \
  --output text)
[ -z "$USER_POOL_ID" ] && fail "Failed to create Cognito User Pool."
ok "User Pool created! ID: $USER_POOL_ID"

# --- Create App Client ---
info "Creating App Client: $COGNITO_CLIENT_NAME ..."
APP_CLIENT_ID=$(aws cognito-idp create-user-pool-client \
  --user-pool-id "$USER_POOL_ID" \
  --client-name "$COGNITO_CLIENT_NAME" \
  --no-generate-secret \
  --explicit-auth-flows ALLOW_USER_PASSWORD_AUTH ALLOW_REFRESH_TOKEN_AUTH \
  --region "$REGION" \
  --query 'UserPoolClient.ClientId' \
  --output text)
[ -z "$APP_CLIENT_ID" ] && fail "Failed to create Cognito App Client."
ok "App Client created! ID: $APP_CLIENT_ID"

# --- Create Groups ---
info "Creating group: $GROUP1 ..."
aws cognito-idp create-group \
  --user-pool-id "$USER_POOL_ID" \
  --group-name "$GROUP1" \
  --description "Administrator group" \
  --region "$REGION" > /dev/null
ok "Group '$GROUP1' created"

info "Creating group: $GROUP2 ..."
aws cognito-idp create-group \
  --user-pool-id "$USER_POOL_ID" \
  --group-name "$GROUP2" \
  --description "Standard users / students" \
  --region "$REGION" > /dev/null
ok "Group '$GROUP2' created"

# --- Create Test User ---
info "Creating test user: $USERNAME ..."
aws cognito-idp admin-create-user \
  --user-pool-id "$USER_POOL_ID" \
  --username "$USERNAME" \
  --message-action SUPPRESS \
  --region "$REGION" > /dev/null
ok "User '$USERNAME' created"

# --- Set Permanent Password ---
info "Setting permanent password for $USERNAME ..."
aws cognito-idp admin-set-user-password \
  --user-pool-id "$USER_POOL_ID" \
  --username "$USERNAME" \
  --password "$PASSWORD" \
  --permanent \
  --region "$REGION"
ok "Permanent password set for '$USERNAME'"
sleep 3  # Allow Cognito to propagate password before auth test

# --- Add User to Group ---
info "Adding $USERNAME to group '$GROUP1' ..."
aws cognito-idp admin-add-user-to-group \
  --user-pool-id "$USER_POOL_ID" \
  --username "$USERNAME" \
  --group-name "$GROUP1" \
  --region "$REGION"
ok "'$USERNAME' added to '$GROUP1'"

# --- Test Authentication ---
info "Testing Cognito authentication for $USERNAME ..."
AUTH_RESULT=$(aws cognito-idp initiate-auth \
  --auth-flow USER_PASSWORD_AUTH \
  --client-id "$APP_CLIENT_ID" \
  --auth-parameters USERNAME="$USERNAME",PASSWORD="$PASSWORD" \
  --region "$REGION" \
  --query 'AuthenticationResult' \
  --output json)

if [ -z "$AUTH_RESULT" ] || [ "$AUTH_RESULT" = "null" ]; then
  fail "Cognito authentication test failed."
fi
echo "$AUTH_RESULT" | grep -E '"(TokenType|ExpiresIn)"' || true
ok "Cognito authentication test PASSED"

# ── 13. Build & Upload index.html ─────────────────────────────
step "Step 13: Upload Website"
info "Generating index.html with live API and Cognito config..."

cat > $TMPDIR/index.html << HTMLEOF
<!DOCTYPE html>
<html lang="en">
<head>
<meta charset="UTF-8">
<meta name="viewport" content="width=device-width, initial-scale=1.0">
<title>IT Support Ticketing System</title>
<link rel="stylesheet" href="https://cdn.jsdelivr.net/npm/@tabler/icons-webfont@3.19.0/dist/tabler-icons.min.css">
<style>
  *, *::before, *::after { box-sizing: border-box; margin: 0; padding: 0; }
  :root {
    --bg-primary: #ffffff; --bg-secondary: #f7f7f5; --bg-tertiary: #f0efeb;
    --bg-info: #e6f1fb; --bg-danger: #fcebeb; --bg-success: #eaf3de; --bg-warning: #faeeda;
    --text-primary: #1a1a18; --text-secondary: #5f5e5a; --text-tertiary: #888780;
    --text-info: #0c447c; --text-danger: #791f1f; --text-success: #27500a; --text-warning: #633806;
    --border-t: rgba(0,0,0,0.10); --border-s: rgba(0,0,0,0.18); --border-p: rgba(0,0,0,0.28);
    --radius-md: 8px; --radius-lg: 12px;
    --font: -apple-system, BlinkMacSystemFont, 'Segoe UI', system-ui, sans-serif;
    --nav-w: 52px; --panel-w: 320px;
  }
  @media (prefers-color-scheme: dark) {
    :root {
      --bg-primary: #1c1c1a; --bg-secondary: #242422; --bg-tertiary: #2c2c2a;
      --bg-info: #042c53; --bg-danger: #501313; --bg-success: #173404; --bg-warning: #412402;
      --text-primary: #f0efe9; --text-secondary: #a8a79f; --text-tertiary: #6e6d67;
      --text-info: #85b7eb; --text-danger: #f09595; --text-success: #97c459; --text-warning: #ef9f27;
      --border-t: rgba(255,255,255,0.08); --border-s: rgba(255,255,255,0.15); --border-p: rgba(255,255,255,0.25);
    }
  }
  html, body { height: 100%; font-family: var(--font); background: var(--bg-tertiary); color: var(--text-primary); }

  /* Auth gate overlay */
  .auth-gate { position: fixed; inset: 0; background: var(--bg-tertiary); z-index: 200; display: flex; align-items: center; justify-content: center; }
  .auth-gate.hidden { display: none; }
  .auth-card {
    background: var(--bg-primary); border: 0.5px solid var(--border-s);
    border-radius: var(--radius-lg); width: 380px; max-width: 94vw;
    box-shadow: 0 8px 32px rgba(0,0,0,0.12);
  }
  .auth-hd { padding: 20px 24px 14px; border-bottom: 0.5px solid var(--border-t); }
  .auth-logo { display: flex; align-items: center; gap: 10px; margin-bottom: 14px; }
  .auth-logo-icon { width: 34px; height: 34px; border-radius: 8px; background: var(--text-primary); display: flex; align-items: center; justify-content: center; }
  .auth-logo-icon i { font-size: 17px; color: var(--bg-primary); }
  .auth-logo-name { font-size: 13px; font-weight: 600; color: var(--text-primary); }
  .auth-logo-sub  { font-size: 11px; color: var(--text-tertiary); }
  .auth-hd h2 { font-size: 15px; font-weight: 600; margin-bottom: 3px; }
  .auth-hd p  { font-size: 12px; color: var(--text-secondary); }
  .auth-bd { padding: 18px 24px; display: flex; flex-direction: column; gap: 12px; }
  .auth-fg { display: flex; flex-direction: column; gap: 4px; }
  .auth-fg label { font-size: 11px; font-weight: 500; color: var(--text-secondary); letter-spacing: 0.03em; }
  .auth-fg input {
    font-size: 13px; font-family: var(--font); padding: 8px 11px;
    border: 0.5px solid var(--border-s); border-radius: var(--radius-md);
    background: var(--bg-primary); color: var(--text-primary); outline: none; width: 100%;
  }
  .auth-fg input:focus { border-color: var(--border-p); box-shadow: 0 0 0 2px rgba(55,138,221,0.15); }
  .auth-err { font-size: 12px; color: var(--text-danger); background: var(--bg-danger); border: 0.5px solid rgba(121,31,31,0.2); border-radius: var(--radius-md); padding: 8px 11px; display: none; }
  .auth-err.show { display: block; }
  .btn-auth { width: 100%; padding: 9px; font-size: 13px; font-weight: 600; font-family: var(--font); border: none; border-radius: var(--radius-md); background: var(--text-primary); color: var(--bg-primary); cursor: pointer; transition: opacity 0.15s; display: flex; align-items: center; justify-content: center; gap: 6px; }
  .btn-auth:hover { opacity: 0.82; }
  .btn-auth:disabled { opacity: 0.45; cursor: not-allowed; }
  .auth-ft { padding: 12px 24px; border-top: 0.5px solid var(--border-t); font-size: 11px; color: var(--text-tertiary); text-align: center; }
  .auth-ft span { color: var(--text-secondary); font-weight: 500; }
  .cognito-badge { display: inline-flex; align-items: center; gap: 4px; font-size: 11px; color: var(--text-info); background: var(--bg-info); border: 0.5px solid rgba(12,68,124,0.15); border-radius: 99px; padding: 2px 9px; margin-top: 4px; }

  /* Spinner */
  .spin { display: inline-block; width: 13px; height: 13px; border: 2px solid rgba(255,255,255,0.3); border-top-color: var(--bg-primary); border-radius: 50%; animation: sp 0.7s linear infinite; }
  @keyframes sp { to { transform: rotate(360deg); } }

  /* App shell */
  .app { display: flex; height: 100vh; background: var(--bg-primary); overflow: hidden; }

  /* User pill in topbar */
  .user-pill { display: inline-flex; align-items: center; gap: 6px; font-size: 11px; padding: 4px 10px 4px 6px; background: var(--bg-secondary); border: 0.5px solid var(--border-t); border-radius: 99px; cursor: default; }
  .user-pill-av { width: 20px; height: 20px; border-radius: 50%; background: var(--text-primary); display: flex; align-items: center; justify-content: center; }
  .user-pill-av i { font-size: 11px; color: var(--bg-primary); }
  .user-pill-name { color: var(--text-primary); font-weight: 500; }
  .btn-signout { font-size: 11px; padding: 4px 9px; border-radius: var(--radius-md); border: 0.5px solid var(--border-s); background: transparent; color: var(--text-secondary); font-family: var(--font); cursor: pointer; transition: background 0.1s; }
  .btn-signout:hover { background: var(--bg-secondary); color: var(--text-primary); }

  /* Ticket submit toast */
  .toast { position: fixed; bottom: 20px; left: 50%; transform: translateX(-50%); background: var(--text-primary); color: var(--bg-primary); padding: 10px 18px; border-radius: var(--radius-md); font-size: 12px; font-weight: 500; z-index: 300; display: none; animation: toastIn 0.25s ease; white-space: nowrap; }
  .toast.show { display: block; }
  @keyframes toastIn { from { opacity: 0; transform: translateX(-50%) translateY(8px); } to { opacity: 1; transform: translateX(-50%) translateY(0); } }

  /* Nav */
  .nav { width: var(--nav-w); background: var(--bg-secondary); border-right: 0.5px solid var(--border-t); display: flex; flex-direction: column; align-items: center; padding: 12px 0; gap: 2px; flex-shrink: 0; }
  .nav-logo { width: 32px; height: 32px; border-radius: 8px; background: var(--text-primary); display: flex; align-items: center; justify-content: center; margin-bottom: 12px; }
  .nav-logo i { font-size: 16px; color: var(--bg-primary); }
  .nav-btn { width: 36px; height: 36px; border-radius: 8px; border: none; background: none; cursor: pointer; display: flex; align-items: center; justify-content: center; color: var(--text-tertiary); position: relative; transition: background 0.12s, color 0.12s; }
  .nav-btn:hover { background: var(--bg-primary); color: var(--text-primary); }
  .nav-btn.active { background: var(--bg-primary); color: var(--text-primary); }
  .nav-btn i { font-size: 18px; }
  .nav-pip { position: absolute; top: 6px; right: 6px; width: 6px; height: 6px; border-radius: 50%; background: #E24B4A; }
  .nav-spacer { flex: 1; }

  /* Sidebar */
  .sidebar { width: 180px; border-right: 0.5px solid var(--border-t); display: flex; flex-direction: column; overflow: hidden; flex-shrink: 0; }
  .sb-head { padding: 16px 14px 10px; border-bottom: 0.5px solid var(--border-t); }
  .sb-head p { font-size: 11px; font-weight: 500; color: var(--text-tertiary); letter-spacing: 0.07em; text-transform: uppercase; margin-bottom: 10px; }
  .sb-search { position: relative; }
  .sb-search i { position: absolute; left: 8px; top: 50%; transform: translateY(-50%); font-size: 14px; color: var(--text-tertiary); pointer-events: none; }
  .sb-search input { padding-left: 28px; width: 100%; font-size: 12px; height: 30px; border: 0.5px solid var(--border-t); border-radius: var(--radius-md); background: var(--bg-primary); color: var(--text-primary); font-family: var(--font); outline: none; }
  .sb-search input:focus { border-color: var(--border-p); box-shadow: 0 0 0 2px rgba(55,138,221,0.15); }
  .sb-scroll { overflow-y: auto; flex: 1; }
  .sb-section { padding: 10px 8px 4px; }
  .sb-label { font-size: 10px; font-weight: 500; color: var(--text-tertiary); letter-spacing: 0.08em; text-transform: uppercase; padding: 0 6px; margin-bottom: 4px; }
  .sb-item { display: flex; align-items: center; gap: 8px; padding: 6px 8px; border-radius: 6px; cursor: pointer; font-size: 12px; color: var(--text-secondary); border: none; background: none; width: 100%; text-align: left; transition: background 0.1s, color 0.1s; font-family: var(--font); }
  .sb-item:hover { background: var(--bg-secondary); color: var(--text-primary); }
  .sb-item.active { background: var(--bg-secondary); color: var(--text-primary); font-weight: 500; }
  .sb-item i { font-size: 14px; width: 16px; flex-shrink: 0; }
  .sb-count { margin-left: auto; font-size: 11px; color: var(--text-tertiary); }
  .sb-count.red { color: #A32D2D; }

  /* Main */
  .main { flex: 1; display: flex; flex-direction: column; min-width: 0; overflow: hidden; }
  .topbar { padding: 0 16px; height: 48px; border-bottom: 0.5px solid var(--border-t); display: flex; align-items: center; gap: 8px; flex-shrink: 0; }
  .topbar-title { font-size: 13px; font-weight: 500; flex: 1; }
  .topbar-filters { display: flex; gap: 4px; }
  .fc { font-size: 11px; padding: 3px 9px; border-radius: 99px; border: 0.5px solid var(--border-t); background: transparent; cursor: pointer; color: var(--text-secondary); font-family: var(--font); transition: all 0.1s; }
  .fc:hover { border-color: var(--border-s); color: var(--text-primary); }
  .fc.active { background: var(--text-primary); color: var(--bg-primary); border-color: var(--text-primary); }
  .btn-new { display: inline-flex; align-items: center; gap: 5px; padding: 5px 11px; font-size: 12px; border-radius: var(--radius-md); cursor: pointer; border: 0.5px solid var(--border-s); background: var(--text-primary); color: var(--bg-primary); font-family: var(--font); font-weight: 500; transition: opacity 0.1s; }
  .btn-new:hover { opacity: 0.82; }
  .btn-new i { font-size: 14px; }

  /* Metrics */
  .metrics { display: grid; grid-template-columns: repeat(4, 1fr); border-bottom: 0.5px solid var(--border-t); flex-shrink: 0; }
  .metric { padding: 12px 14px; border-right: 0.5px solid var(--border-t); }
  .metric:last-child { border-right: none; }
  .metric-n { font-size: 22px; font-weight: 500; line-height: 1; margin-bottom: 3px; }
  .metric-l { font-size: 11px; color: var(--text-tertiary); }
  .c-red { color: #A32D2D; } .c-amber { color: #854F0B; } .c-blue { color: #185FA5; } .c-green { color: #3B6D11; }

  /* Table */
  .tbl-head { display: grid; grid-template-columns: 8px minmax(0,1fr) 92px 84px 64px 28px; gap: 8px; padding: 7px 14px; border-bottom: 0.5px solid var(--border-t); flex-shrink: 0; }
  .tbl-head span { font-size: 10px; font-weight: 500; color: var(--text-tertiary); letter-spacing: 0.06em; text-transform: uppercase; }
  .ticket-list { flex: 1; overflow-y: auto; }
  .trow { display: grid; grid-template-columns: 8px minmax(0,1fr) 92px 84px 64px 28px; gap: 8px; padding: 9px 14px; border-bottom: 0.5px solid var(--border-t); cursor: pointer; align-items: center; transition: background 0.1s; }
  .trow:hover { background: var(--bg-secondary); }
  .trow.sel { background: var(--bg-info); }
  .pdot { width: 8px; height: 8px; border-radius: 50%; flex-shrink: 0; }
  .pcritical { background: #E24B4A; } .phigh { background: #EF9F27; } .pmedium { background: #378ADD; } .plow { background: #639922; }
  .t-title { font-size: 12px; white-space: nowrap; overflow: hidden; text-overflow: ellipsis; color: var(--text-primary); }
  .t-id { font-size: 11px; color: var(--text-tertiary); margin-right: 5px; }
  .spill { display: inline-block; font-size: 10px; padding: 2px 7px; border-radius: 99px; font-weight: 500; }
  .sopen { background: #E6F1FB; color: #0C447C; } .sinprogress { background: #FAEEDA; color: #633806; }
  .sresolved { background: #EAF3DE; color: #27500A; } .sclosed { background: #F1EFE8; color: #5F5E5A; } .swaiting { background: #FBEAF0; color: #4B1528; }
  .t-asgn { font-size: 11px; color: var(--text-secondary); white-space: nowrap; overflow: hidden; text-overflow: ellipsis; }
  .t-pri { font-size: 10px; text-transform: capitalize; font-weight: 500; }
  .t-more { background: none; border: none; cursor: pointer; color: var(--text-tertiary); font-size: 15px; padding: 2px; border-radius: 4px; }
  .t-more:hover { color: var(--text-secondary); background: var(--bg-secondary); }
  .empty { padding: 48px 24px; text-align: center; color: var(--text-tertiary); font-size: 12px; }
  .empty i { font-size: 28px; display: block; margin-bottom: 6px; opacity: 0.4; }

  /* Detail panel */
  .detail { width: var(--panel-w); border-left: 0.5px solid var(--border-t); display: flex; flex-direction: column; overflow: hidden; flex-shrink: 0; }
  .detail.gone { display: none; }
  .dp-top { padding: 14px 16px; border-bottom: 0.5px solid var(--border-t); display: flex; align-items: flex-start; gap: 8px; }
  .dp-top h3 { font-size: 13px; font-weight: 500; flex: 1; line-height: 1.45; }
  .dp-close { background: none; border: none; cursor: pointer; color: var(--text-tertiary); font-size: 17px; padding: 0; flex-shrink: 0; margin-top: 1px; }
  .dp-close:hover { color: var(--text-primary); }
  .dp-scroll { flex: 1; overflow-y: auto; padding: 14px 16px; }
  .dp-meta { display: grid; grid-template-columns: 1fr 1fr; gap: 10px; margin-bottom: 16px; }
  .dp-kv { display: flex; flex-direction: column; gap: 3px; }
  .dp-k { font-size: 10px; font-weight: 500; color: var(--text-tertiary); text-transform: uppercase; letter-spacing: 0.06em; }
  .dp-v { font-size: 12px; }
  .dp-desc { font-size: 12px; color: var(--text-secondary); line-height: 1.65; padding: 10px 12px; border: 0.5px solid var(--border-t); border-radius: var(--radius-md); background: var(--bg-secondary); margin-bottom: 16px; }
  .tl { list-style: none; padding-bottom: 4px; }
  .tl-row { display: flex; gap: 10px; padding-bottom: 12px; position: relative; }
  .tl-row:not(:last-child)::before { content: ''; position: absolute; left: 10px; top: 20px; bottom: 0; width: 0.5px; background: var(--border-t); }
  .tl-ico { width: 20px; height: 20px; border-radius: 50%; border: 0.5px solid var(--border-s); background: var(--bg-secondary); display: flex; align-items: center; justify-content: center; flex-shrink: 0; }
  .tl-ico i { font-size: 11px; color: var(--text-secondary); }
  .tl-body { flex: 1; padding-top: 1px; }
  .tl-msg { font-size: 12px; line-height: 1.5; }
  .tl-t { font-size: 10px; color: var(--text-tertiary); margin-top: 1px; }
  .dp-foot { padding: 10px 14px; border-top: 0.5px solid var(--border-t); display: flex; gap: 6px; }
  .dp-foot select { flex: 1; font-size: 12px; font-family: var(--font); border: 0.5px solid var(--border-s); border-radius: var(--radius-md); background: var(--bg-primary); color: var(--text-primary); padding: 5px 8px; outline: none; }
  .btn-sm { display: inline-flex; align-items: center; gap: 4px; padding: 5px 10px; font-size: 12px; border-radius: var(--radius-md); cursor: pointer; border: 0.5px solid var(--border-s); background: transparent; color: var(--text-secondary); font-family: var(--font); white-space: nowrap; transition: background 0.1s; }
  .btn-sm:hover { background: var(--bg-secondary); color: var(--text-primary); }

  /* Modal */
  .modal-overlay { display: none; position: fixed; inset: 0; background: rgba(0,0,0,0.32); z-index: 50; align-items: center; justify-content: center; }
  .modal-overlay.open { display: flex; }
  .modal { background: var(--bg-primary); border-radius: var(--radius-lg); border: 0.5px solid var(--border-t); width: 440px; max-width: 96vw; }
  .modal-hd { padding: 14px 18px; border-bottom: 0.5px solid var(--border-t); display: flex; align-items: center; justify-content: space-between; }
  .modal-hd h3 { font-size: 14px; font-weight: 500; }
  .modal-bd { padding: 16px 18px; display: flex; flex-direction: column; gap: 12px; }
  .fg { display: flex; flex-direction: column; gap: 4px; }
  .fg label { font-size: 11px; font-weight: 500; color: var(--text-secondary); letter-spacing: 0.03em; }
  .fg2 { display: grid; grid-template-columns: 1fr 1fr; gap: 10px; }
  .fg input, .fg select, .fg textarea { font-size: 12px; font-family: var(--font); border: 0.5px solid var(--border-s); border-radius: var(--radius-md); background: var(--bg-primary); color: var(--text-primary); padding: 7px 10px; outline: none; width: 100%; }
  .fg input:focus, .fg select:focus, .fg textarea:focus { border-color: var(--border-p); box-shadow: 0 0 0 2px rgba(55,138,221,0.15); }
  .fg textarea { resize: vertical; min-height: 72px; }
  .modal-ft { padding: 10px 18px; border-top: 0.5px solid var(--border-t); display: flex; justify-content: flex-end; gap: 6px; }
  .modal-note { font-size: 11px; color: var(--text-success); background: var(--bg-success); border: 0.5px solid rgba(39,80,10,0.2); border-radius: var(--radius-md); padding: 7px 10px; display: none; }
  .modal-note.show { display: block; }
  .modal-err { font-size: 11px; color: var(--text-danger); background: var(--bg-danger); border: 0.5px solid rgba(121,31,31,0.2); border-radius: var(--radius-md); padding: 7px 10px; display: none; }
  .modal-err.show { display: block; }

  ::-webkit-scrollbar { width: 5px; }
  ::-webkit-scrollbar-track { background: transparent; }
  ::-webkit-scrollbar-thumb { background: var(--border-s); border-radius: 99px; }
</style>
</head>
<body>

<!-- ── Auth gate ───────────────────────────────────────────── -->
<div class="auth-gate" id="auth-gate">
  <div class="auth-card">
    <div class="auth-hd">
      <div class="auth-logo">
        <div class="auth-logo-icon"><i class="ti ti-headset"></i></div>
        <div>
          <div class="auth-logo-name">IT Support</div>
          <div class="auth-logo-sub">Ticketing System</div>
        </div>
      </div>
      <h2>Sign in to continue</h2>
      <p>Use your Amazon Cognito credentials to access the portal.</p>
    </div>
    <div class="auth-bd">
      <div class="auth-fg">
        <label>Username</label>
        <input type="text" id="auth-user" placeholder="student1" autocomplete="username"/>
      </div>
      <div class="auth-fg">
        <label>Password</label>
        <input type="password" id="auth-pass" placeholder="••••••••" autocomplete="current-password"
          onkeydown="if(event.key==='Enter') doSignIn()"/>
      </div>
      <div class="auth-err" id="auth-err"></div>
      <button class="btn-auth" id="auth-btn" onclick="doSignIn()">
        <i class="ti ti-login"></i> Sign in
      </button>
    </div>
    <div class="auth-ft">
      Protected by <span>Amazon Cognito</span> &nbsp;·&nbsp;
      <span class="cognito-badge"><i class="ti ti-shield-check" style="font-size:12px"></i> AWS Authentication</span>
    </div>
  </div>
</div>

<!-- ── Toast ──────────────────────────────────────────────── -->
<div class="toast" id="toast"></div>

<!-- ── App shell (hidden until signed in) ─────────────────── -->
<div class="app" id="app-shell" style="display:none">

  <!-- Icon rail -->
  <nav class="nav">
    <div class="nav-logo"><i class="ti ti-headset"></i></div>
    <button class="nav-btn active" title="Tickets"><i class="ti ti-ticket"></i><span class="nav-pip"></span></button>
    <button class="nav-btn" title="Dashboard" onclick="alert('Dashboard — extend this app to add analytics charts.')"><i class="ti ti-chart-bar"></i></button>
    <button class="nav-btn" title="Team" onclick="alert('Team view — extend this app to show agent workloads.')"><i class="ti ti-users"></i></button>
    <button class="nav-btn" title="Knowledge base" onclick="alert('Knowledge base — extend this app to link articles.')"><i class="ti ti-book"></i></button>
    <div class="nav-spacer"></div>
    <button class="nav-btn" title="Settings" onclick="alert('Settings — configure queues, SLAs, and notifications.')"><i class="ti ti-settings"></i></button>
  </nav>

  <!-- Sidebar -->
  <aside class="sidebar">
    <div class="sb-head">
      <p>Helpdesk</p>
      <div class="sb-search">
        <i class="ti ti-search"></i>
        <input type="text" id="srch" placeholder="Search…" oninput="render()">
      </div>
    </div>
    <div class="sb-scroll">
      <div class="sb-section">
        <div class="sb-label">Queues</div>
        <button class="sb-item active" id="nav-all"        onclick="nav('all',this)">           <i class="ti ti-inbox"></i>        All tickets    <span class="sb-count" id="c-all">0</span></button>
        <button class="sb-item"        id="nav-open"       onclick="nav('open',this)">          <i class="ti ti-circle-dot"></i>   Open           <span class="sb-count red" id="c-open">0</span></button>
        <button class="sb-item"        id="nav-inprogress" onclick="nav('inprogress',this)">    <i class="ti ti-loader"></i>       In progress    <span class="sb-count" id="c-inprogress">0</span></button>
        <button class="sb-item"        id="nav-waiting"    onclick="nav('waiting',this)">       <i class="ti ti-clock-pause"></i>  Waiting        <span class="sb-count" id="c-waiting"></span></button>
        <button class="sb-item"        id="nav-resolved"   onclick="nav('resolved',this)">      <i class="ti ti-circle-check"></i> Resolved       <span class="sb-count" id="c-resolved"></span></button>
        <button class="sb-item"        id="nav-closed"     onclick="nav('closed',this)">        <i class="ti ti-archive"></i>      Closed         <span class="sb-count" id="c-closed"></span></button>
      </div>
      <div class="sb-section">
        <div class="sb-label">Views</div>
        <button class="sb-item" onclick="nav('critical',this)">    <i class="ti ti-alert-circle" style="color:#E24B4A"></i> Critical <span class="sb-count red" id="c-critical"></span></button>
        <button class="sb-item" onclick="nav('mine',this)">        <i class="ti ti-user-check"></i>Mine</button>
        <button class="sb-item" onclick="nav('unassigned',this)">  <i class="ti ti-user-x"></i>Unassigned</button>
      </div>
      <div class="sb-section">
        <div class="sb-label">Category</div>
        <button class="sb-item" onclick="nav('Hardware',this)">            <i class="ti ti-cpu"></i>Hardware</button>
        <button class="sb-item" onclick="nav('Software',this)">            <i class="ti ti-app-window"></i>Software</button>
        <button class="sb-item" onclick="nav('Network',this)">             <i class="ti ti-network"></i>Network</button>
        <button class="sb-item" onclick="nav('Access & Permissions',this)"><i class="ti ti-lock"></i>Access</button>
        <button class="sb-item" onclick="nav('Email',this)">               <i class="ti ti-mail"></i>Email</button>
      </div>
    </div>
  </aside>

  <!-- Main content -->
  <div class="main">
    <div class="topbar">
      <span class="topbar-title" id="view-lbl">All tickets</span>
      <div class="topbar-filters">
        <button class="fc active" onclick="pri('all',this)">All</button>
        <button class="fc" onclick="pri('critical',this)">Critical</button>
        <button class="fc" onclick="pri('high',this)">High</button>
        <button class="fc" onclick="pri('medium',this)">Medium</button>
        <button class="fc" onclick="pri('low',this)">Low</button>
      </div>
      <div class="user-pill" id="user-pill">
        <div class="user-pill-av"><i class="ti ti-user"></i></div>
        <span class="user-pill-name" id="user-pill-name">—</span>
      </div>
      <button class="btn-signout" onclick="doSignOut()"><i class="ti ti-logout" style="font-size:12px"></i> Sign out</button>
      <button class="btn-new" onclick="openModal()"><i class="ti ti-plus"></i>New ticket</button>
    </div>

    <div class="metrics" id="metrics"></div>

    <div class="tbl-head">
      <span></span><span>Title</span><span>Status</span><span>Assignee</span><span>Priority</span><span></span>
    </div>
    <div class="ticket-list" id="tlist"></div>
  </div>

  <!-- Detail panel -->
  <div class="detail gone" id="dp"></div>

</div><!-- /.app -->

<!-- New ticket modal -->
<div class="modal-overlay" id="modal-overlay">
  <div class="modal">
    <div class="modal-hd">
      <h3>New support ticket</h3>
      <button class="dp-close" onclick="closeModal()"><i class="ti ti-x"></i></button>
    </div>
    <div class="modal-bd">
      <div class="modal-note" id="modal-note"></div>
      <div class="modal-err"  id="modal-err"></div>
      <div class="fg"><label>Title *</label><input type="text" id="f-title" placeholder="Brief summary of the issue"></div>
      <div class="fg2">
        <div class="fg"><label>Category</label>
          <select id="f-cat">
            <option>Hardware</option><option>Software</option><option>Network</option>
            <option>Access &amp; Permissions</option><option>Email</option><option>Other</option>
          </select>
        </div>
        <div class="fg"><label>Priority</label>
          <select id="f-pri">
            <option value="low">Low</option><option value="medium" selected>Medium</option>
            <option value="high">High</option><option value="critical">Critical</option>
          </select>
        </div>
      </div>
      <div class="fg2">
        <div class="fg"><label>Requester</label><input type="text" id="f-req" placeholder="Full name"></div>
        <div class="fg"><label>Email</label><input type="email" id="f-email" placeholder="user@company.com"></div>
      </div>
      <div class="fg2">
        <div class="fg"><label>Assign to</label>
          <select id="f-asgn">
            <option>Unassigned</option><option>Alex Kim</option><option>Jordan Lee</option>
            <option>Sam Patel</option><option>Morgan Chen</option>
          </select>
        </div>
        <div class="fg"><label>Category</label>
          <select id="f-cat2" style="display:none"></select>
        </div>
      </div>
      <div class="fg"><label>Description</label><textarea id="f-desc" placeholder="Describe the issue in detail…"></textarea></div>
    </div>
    <div class="modal-ft">
      <button class="btn-sm" onclick="closeModal()">Cancel</button>
      <button class="btn-new" id="submit-btn" onclick="submitTicket()"><i class="ti ti-send"></i>Submit ticket</button>
    </div>
  </div>
</div>

<script>
/* ── AWS Config (injected by deploy script) ── */
const API_ENDPOINT  = "$API_ENDPOINT";
const USER_POOL_ID  = "$USER_POOL_ID";
const APP_CLIENT_ID = "$APP_CLIENT_ID";
const COGNITO_REGION = "$REGION";

/* ── Auth state ── */
let idToken = null;
let currentUser = null;

async function doSignIn() {
  const username = document.getElementById('auth-user').value.trim();
  const password = document.getElementById('auth-pass').value;
  const errEl    = document.getElementById('auth-err');
  const btn      = document.getElementById('auth-btn');
  errEl.className = 'auth-err';

  if (!username || !password) {
    errEl.textContent = 'Please enter your username and password.';
    errEl.className = 'auth-err show'; return;
  }

  btn.disabled = true;
  btn.innerHTML = '<span class="spin"></span> Signing in…';

  try {
    const res = await fetch(
      'https://cognito-idp.' + COGNITO_REGION + '.amazonaws.com/',
      {
        method: 'POST',
        headers: {
          'Content-Type': 'application/x-amz-json-1.1',
          'X-Amz-Target': 'AWSCognitoIdentityProviderService.InitiateAuth'
        },
        body: JSON.stringify({
          AuthFlow: 'USER_PASSWORD_AUTH',
          ClientId: APP_CLIENT_ID,
          AuthParameters: { USERNAME: username, PASSWORD: password }
        })
      }
    );
    const data = await res.json();
    if (data.__type) throw new Error(data.message || data.__type);

    idToken     = data.AuthenticationResult.IdToken;
    currentUser = username;

    document.getElementById('auth-gate').classList.add('hidden');
    document.getElementById('app-shell').style.display = 'flex';
    document.getElementById('user-pill-name').textContent = username;
    showToast('Signed in as ' + username);
    render();
  } catch (err) {
    errEl.textContent = 'Sign-in failed: ' + (err.message || 'Invalid credentials');
    errEl.className   = 'auth-err show';
  } finally {
    btn.disabled = false;
    btn.innerHTML = '<i class="ti ti-login"></i> Sign in';
  }
}

function doSignOut() {
  idToken = null; currentUser = null;
  document.getElementById('auth-gate').classList.remove('hidden');
  document.getElementById('app-shell').style.display = 'none';
  document.getElementById('auth-pass').value = '';
  document.getElementById('auth-err').className = 'auth-err';
}

/* ── Toast ── */
function showToast(msg) {
  const t = document.getElementById('toast');
  t.textContent = msg; t.className = 'toast show';
  setTimeout(() => { t.className = 'toast'; }, 3000);
}

/* ── Ticket data ── */
let T = [
  { id:'INC-0047', title:'Laptop not connecting to VPN after Windows update', cat:'Network', pri:'critical', status:'open', assignee:'Alex Kim', req:'Priya Shah', email:'priya@company.com', created:'2026-05-07', desc:'User updated Windows yesterday and cannot connect to corporate VPN. Error code 800. Other users on same network unaffected.', log:[{i:'ti-ticket',m:'Ticket created by Priya Shah',t:'Today 08:12'},{i:'ti-user-plus',m:'Assigned to Alex Kim',t:'Today 08:15'}] },
  { id:'INC-0046', title:'Outlook not syncing emails on mobile device', cat:'Email', pri:'high', status:'inprogress', assignee:'Jordan Lee', req:'Tom Watkins', email:'tom@company.com', created:'2026-05-06', desc:'Outlook mobile stopped syncing 2 days ago. Web version works fine. Device: iPhone 15, iOS 17.4.', log:[{i:'ti-ticket',m:'Ticket created by Tom Watkins',t:'Yesterday 14:22'},{i:'ti-user-plus',m:'Assigned to Jordan Lee',t:'Yesterday 14:30'},{i:'ti-message',m:'Jordan: Checking MDM policy.',t:'Today 09:01'}] },
  { id:'INC-0045', title:'Shared printer offline — Building C, Floor 2', cat:'Hardware', pri:'high', status:'inprogress', assignee:'Sam Patel', req:'Dana Cruz', email:'dana@company.com', created:'2026-05-06', desc:'HP LaserJet 4015 showing offline. 12 staff affected. Last print job was Monday.', log:[{i:'ti-ticket',m:'Ticket created by Dana Cruz',t:'Yesterday 11:05'},{i:'ti-user-plus',m:'Assigned to Sam Patel',t:'Yesterday 11:10'}] },
  { id:'INC-0044', title:'Access request: Salesforce CRM for new hire', cat:'Access & Permissions', pri:'medium', status:'waiting', assignee:'Morgan Chen', req:'HR — Liz Nguyen', email:'liz@company.com', created:'2026-05-05', desc:'New employee Marcus Rivera (Marketing) needs Salesforce Standard User access.', log:[{i:'ti-ticket',m:'Ticket created',t:'Mon 09:30'},{i:'ti-clock',m:'Awaiting manager approval',t:'Mon 10:00'}] },
  { id:'INC-0043', title:'Blue screen — MEMORY_MANAGEMENT on finance workstation', cat:'Hardware', pri:'critical', status:'open', assignee:'Alex Kim', req:'Carla Roth', email:'carla@company.com', created:'2026-05-05', desc:'BSOD occurring multiple times daily. Error: MEMORY_MANAGEMENT. Machine is 4 years old.', log:[{i:'ti-ticket',m:'Ticket created',t:'Mon 15:45'},{i:'ti-user-plus',m:'Assigned to Alex Kim',t:'Mon 15:50'}] },
  { id:'INC-0042', title:'Software install: Adobe Creative Cloud', cat:'Software', pri:'low', status:'resolved', assignee:'Jordan Lee', req:'Ben Nakamura', email:'ben@company.com', created:'2026-05-04', desc:'Designer needs Adobe CC installed on new MacBook Pro. License available in portal.', log:[{i:'ti-ticket',m:'Ticket created',t:'Sun 10:00'},{i:'ti-circle-check',m:'Adobe CC installed and activated.',t:'Mon 11:30'}] },
  { id:'INC-0041', title:'Wi-Fi dropping every 20–30 min — Conference Room 4B', cat:'Network', pri:'medium', status:'inprogress', assignee:'Sam Patel', req:'Facilities', email:'facilities@company.com', created:'2026-05-04', desc:'Connectivity drops intermittently after AP firmware update last Thursday.', log:[{i:'ti-ticket',m:'Ticket created',t:'Sun 09:00'},{i:'ti-message',m:'Sam: AP logs show auth timeouts.',t:'Mon 14:00'}] },
  { id:'INC-0040', title:'Password reset after account lockout', cat:'Access & Permissions', pri:'low', status:'resolved', assignee:'Morgan Chen', req:'James Osei', email:'james@company.com', created:'2026-05-03', desc:'User locked after 5 failed attempts. Password reset and MFA re-enrollment required.', log:[{i:'ti-ticket',m:'Ticket created',t:'Sat 08:22'},{i:'ti-circle-check',m:'Password reset and MFA re-enrolled.',t:'Sat 09:10'}] },
  { id:'INC-0039', title:'Slow file transfers on shared network drive', cat:'Network', pri:'medium', status:'open', assignee:'Unassigned', req:'Ops Team', email:'ops@company.com', created:'2026-05-03', desc:'Transfers to \\\\fs01\\shared are under 1 Mbps. Entire ops dept affected since Friday.', log:[{i:'ti-ticket',m:'Ticket created',t:'Sat 10:15'}] },
  { id:'INC-0038', title:'MFA enforcement rollout for exec team', cat:'Access & Permissions', pri:'high', status:'open', assignee:'Morgan Chen', req:'CISO Office', email:'ciso@company.com', created:'2026-05-01', desc:'All C-suite members need MFA enforced by end of week per new security policy.', log:[{i:'ti-ticket',m:'Ticket created',t:'Thu 11:00'},{i:'ti-user-plus',m:'Assigned to Morgan Chen',t:'Thu 11:05'}] }
];

let vw = 'all', pf = 'all', sel = null;
const VIEW_LABELS = { all:'All tickets', open:'Open', inprogress:'In progress', waiting:'Waiting', resolved:'Resolved', closed:'Closed', critical:'Critical', mine:'Assigned to me', unassigned:'Unassigned', Hardware:'Hardware', Software:'Software', Network:'Network', 'Access & Permissions':'Access & Permissions', Email:'Email' };
const STATUSES = ['open','inprogress','waiting','resolved','closed'];

function sl(s)  { return s === 'inprogress' ? 'In progress' : s.charAt(0).toUpperCase() + s.slice(1); }
function sc(s)  { return 'spill s' + s.replace(/\s/g,''); }
function pc(p)  { return 'pdot p' + p; }
function pcol(p){ return p==='critical'?'#A32D2D':p==='high'?'#854F0B':p==='medium'?'#185FA5':'#3B6D11'; }
function fd(d)  { const n=new Date(d),now=new Date(),diff=Math.floor((now-n)/86400000); if(diff===0)return 'Today'; if(diff===1)return 'Yesterday'; return n.toLocaleDateString('en-US',{month:'short',day:'numeric'}); }

function getQ() {
  const q = (document.getElementById('srch').value || '').toLowerCase();
  return T.filter(t => {
    if      (vw==='all')        { }
    else if (vw==='mine')       { if (t.assignee !== currentUser && t.assignee !== 'Alex Kim') return false; }
    else if (vw==='unassigned') { if (t.assignee !== 'Unassigned') return false; }
    else if (vw==='critical')   { if (t.pri !== 'critical') return false; }
    else if (['Hardware','Software','Network','Access & Permissions','Email'].includes(vw)) { if(t.cat!==vw)return false; }
    else if (t.status !== vw) return false;
    if (pf !== 'all' && t.pri !== pf) return false;
    if (q && !t.title.toLowerCase().includes(q) && !t.id.toLowerCase().includes(q) && !t.assignee.toLowerCase().includes(q)) return false;
    return true;
  });
}

function render() {
  const rows = getQ();
  const lst  = document.getElementById('tlist');
  lst.innerHTML = rows.length
    ? rows.map(t => \`<div class="trow\${sel===t.id?' sel':''}" onclick="selTicket('\${t.id}')"><span class="\${pc(t.pri)}" title="\${t.pri}"></span><span class="t-title"><span class="t-id">\${t.id}</span>\${t.title}</span><span class="\${sc(t.status)}">\${sl(t.status)}</span><span class="t-asgn">\${t.assignee}</span><span class="t-pri" style="color:\${pcol(t.pri)}">\${t.pri}</span><button class="t-more" onclick="event.stopPropagation()" title="More"><i class="ti ti-dots-vertical"></i></button></div>\`).join('')
    : '<div class="empty"><i class="ti ti-inbox"></i>No tickets match this filter</div>';
  updMetrics(); updCounts();
}

function updMetrics() {
  document.getElementById('metrics').innerHTML = \`
    <div class="metric"><div class="metric-n c-red">\${T.filter(t=>t.status==='open').length}</div><div class="metric-l">Open</div></div>
    <div class="metric"><div class="metric-n c-amber">\${T.filter(t=>t.status==='inprogress').length}</div><div class="metric-l">In progress</div></div>
    <div class="metric"><div class="metric-n c-red">\${T.filter(t=>t.pri==='critical'&&!['resolved','closed'].includes(t.status)).length}</div><div class="metric-l">Critical active</div></div>
    <div class="metric"><div class="metric-n c-green">\${T.filter(t=>['resolved','closed'].includes(t.status)).length}</div><div class="metric-l">Resolved</div></div>\`;
}

function updCounts() {
  const sets = { all:T.length, open:T.filter(t=>t.status==='open').length, inprogress:T.filter(t=>t.status==='inprogress').length, waiting:T.filter(t=>t.status==='waiting').length, resolved:T.filter(t=>t.status==='resolved').length, closed:T.filter(t=>t.status==='closed').length, critical:T.filter(t=>t.pri==='critical').length };
  Object.entries(sets).forEach(([k,v]) => { const el = document.getElementById('c-'+k); if(el) el.textContent = v||''; });
}

function selTicket(id) {
  sel = id;
  const t = T.find(x => x.id === id);
  if (!t) return;
  const dp = document.getElementById('dp');
  dp.classList.remove('gone');
  dp.innerHTML = \`
    <div class="dp-top">
      <div style="flex:1"><div style="font-size:10px;color:var(--text-tertiary);margin-bottom:4px">\${t.id} · \${t.cat}</div><h3>\${t.title}</h3></div>
      <button class="dp-close" onclick="closeDP()"><i class="ti ti-x"></i></button>
    </div>
    <div class="dp-scroll">
      <div class="dp-meta">
        <div class="dp-kv"><span class="dp-k">Status</span><span class="\${sc(t.status)}" style="display:inline-block;margin-top:2px">\${sl(t.status)}</span></div>
        <div class="dp-kv"><span class="dp-k">Priority</span><span class="dp-v" style="color:\${pcol(t.pri)};font-weight:500;text-transform:capitalize">\${t.pri}</span></div>
        <div class="dp-kv"><span class="dp-k">Assignee</span><span class="dp-v">\${t.assignee}</span></div>
        <div class="dp-kv"><span class="dp-k">Requester</span><span class="dp-v">\${t.req}</span></div>
        <div class="dp-kv"><span class="dp-k">Opened</span><span class="dp-v">\${fd(t.created)}</span></div>
        <div class="dp-kv"><span class="dp-k">Category</span><span class="dp-v">\${t.cat}</span></div>
      </div>
      <div class="dp-desc">\${t.desc}</div>
      <div class="dp-k" style="margin-bottom:8px">Activity</div>
      <ul class="tl">\${t.log.map(e=>\`<li class="tl-row"><div class="tl-ico"><i class="ti \${e.i}"></i></div><div class="tl-body"><div class="tl-msg">\${e.m}</div><div class="tl-t">\${e.t}</div></div></li>\`).join('')}</ul>
    </div>
    <div class="dp-foot">
      <select id="dp-sel" onchange="updStatus('\${t.id}', this.value)">\${STATUSES.map(s=>\`<option value="\${s}"\${t.status===s?' selected':''}>\${sl(s)}</option>\`).join('')}</select>
      <button class="btn-sm" onclick="alert('AI help: connect an AI API to suggest resolution steps.')"><i class="ti ti-sparkles"></i>AI help</button>
    </div>\`;
  render();
}

function closeDP() { sel = null; document.getElementById('dp').classList.add('gone'); render(); }

function updStatus(id, ns) {
  const t = T.find(x => x.id === id);
  if (!t) return;
  const os = t.status; t.status = ns;
  t.log.push({ i:'ti-refresh', m:\`Status: \${sl(os)} → \${sl(ns)}\`, t:'Just now' });
  selTicket(id);
}

function nav(v, el) {
  vw = v;
  document.querySelectorAll('.sb-item').forEach(e => e.classList.remove('active'));
  el.classList.add('active');
  document.getElementById('view-lbl').textContent = VIEW_LABELS[v] || v;
  closeDP(); render();
}

function pri(p, el) {
  pf = p;
  document.querySelectorAll('.fc').forEach(e => e.classList.remove('active'));
  el.classList.add('active');
  render();
}

function openModal()  { document.getElementById('modal-overlay').classList.add('open'); document.getElementById('modal-note').className='modal-note'; document.getElementById('modal-err').className='modal-err'; }
function closeModal() {
  document.getElementById('modal-overlay').classList.remove('open');
  ['f-title','f-desc','f-req','f-email'].forEach(id => { document.getElementById(id).value = ''; });
}

async function submitTicket() {
  const title  = (document.getElementById('f-title').value || '').trim();
  const desc   = (document.getElementById('f-desc').value  || '').trim();
  const req    = (document.getElementById('f-req').value   || '').trim();
  const email  = (document.getElementById('f-email').value || '').trim();
  const cat    = document.getElementById('f-cat').value;
  const pri2   = document.getElementById('f-pri').value;
  const asgn   = document.getElementById('f-asgn').value;
  const noteEl = document.getElementById('modal-note');
  const errEl  = document.getElementById('modal-err');
  const btn    = document.getElementById('submit-btn');

  noteEl.className = 'modal-note'; errEl.className = 'modal-err';
  if (!title) { errEl.textContent = 'Title is required.'; errEl.className='modal-err show'; document.getElementById('f-title').focus(); return; }

  btn.disabled = true;
  btn.innerHTML = '<span class="spin"></span> Submitting…';

  const payload = {
    title, description: desc, requester: req || currentUser,
    email, category: cat, priority: pri2, assignee: asgn,
    submittedBy: currentUser
  };

  try {
    const res = await fetch(API_ENDPOINT + '/submit', {
      method: 'POST',
      headers: { 'Content-Type': 'application/json', 'Authorization': idToken },
      body: JSON.stringify(payload)
    });
    const data = await res.json();
    if (!res.ok) throw new Error(data.error || 'Submission failed');

    const ticketId = data.ticketId || ('INC-' + Math.random().toString(36).substr(2,6).toUpperCase());

    /* Add locally so it shows immediately */
    T.unshift({
      id: ticketId, title, cat, pri: pri2, status: 'open', assignee: asgn,
      req: req || currentUser, email, created: new Date().toISOString().split('T')[0],
      desc: desc || 'No description provided.',
      log: [{ i:'ti-ticket', m:\`Ticket submitted by \${currentUser}\`, t:'Just now' },
            ...(asgn !== 'Unassigned' ? [{i:'ti-user-plus',m:\`Assigned to \${asgn}\`,t:'Just now'}] : [])]
    });

    noteEl.textContent = \`✓ Ticket \${ticketId} submitted and queued to AWS SQS. You will receive an email notification.\`;
    noteEl.className = 'modal-note show';
    showToast('Ticket ' + ticketId + ' submitted!');

    document.getElementById('f-title').value = '';
    document.getElementById('f-desc').value  = '';
    document.getElementById('f-req').value   = '';
    document.getElementById('f-email').value = '';

    vw = 'all';
    document.querySelectorAll('.sb-item').forEach(e => e.classList.remove('active'));
    document.getElementById('nav-all').classList.add('active');
    document.getElementById('view-lbl').textContent = 'All tickets';
    render();
    setTimeout(() => selTicket(ticketId), 80);
  } catch(err) {
    errEl.textContent = 'Error: ' + err.message;
    errEl.className = 'modal-err show';
  } finally {
    btn.disabled = false;
    btn.innerHTML = '<i class="ti ti-send"></i>Submit ticket';
  }
}

document.getElementById('modal-overlay').addEventListener('click', function(e) {
  if (e.target === this) closeModal();
});
</script>
</body>
</html>
HTMLEOF

aws s3 cp $TMPDIR/index.html "s3://$BUCKET_NAME/index.html" --content-type "text/html" \
  || fail "Failed to upload index.html"
ok "index.html uploaded to S3 with live Cognito + API config"

# ── 14. Store deployment metadata in DynamoDB ─────────────────
step "Step 14: Store Deployment Metadata"
TIMESTAMP_NOW=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
info "Writing deployment record to DynamoDB..."
aws dynamodb put-item \
  --table-name "$TABLE_NAME" \
  --region "$REGION" \
  --item "{
    \"ProjectName\":          {\"S\": \"$PROJECT_NAME\"},
    \"S3BucketName\":         {\"S\": \"$BUCKET_NAME\"},
    \"S3WebsiteURL\":         {\"S\": \"$S3_WEBSITE_URL\"},
    \"APIGatewayURL\":        {\"S\": \"$API_ENDPOINT\"},
    \"CognitoUserPoolID\":    {\"S\": \"$USER_POOL_ID\"},
    \"CognitoAppClientID\":   {\"S\": \"$APP_CLIENT_ID\"},
    \"SubmitLambda\":         {\"S\": \"$SUBMIT_LAMBDA_NAME\"},
    \"ProcessorLambda\":      {\"S\": \"$PROCESSOR_LAMBDA_NAME\"},
    \"SQSQueueName\":         {\"S\": \"$MAIN_QUEUE_NAME\"},
    \"DLQName\":              {\"S\": \"$DLQ_NAME\"},
    \"SNSTopicName\":         {\"S\": \"$SNS_TOPIC_NAME\"},
    \"SNSTopicARN\":          {\"S\": \"$SNS_TOPIC_ARN\"},
    \"TestUsername\":         {\"S\": \"$USERNAME\"},
    \"CognitoGroups\":        {\"S\": \"$GROUP1, $GROUP2\"},
    \"DeploymentTimestamp\":  {\"S\": \"$TIMESTAMP_NOW\"},
    \"DeploymentStatus\":     {\"S\": \"SUCCESS\"},
    \"Region\":               {\"S\": \"$REGION\"}
  }" || fail "Failed to write deployment metadata to DynamoDB"
ok "Deployment metadata saved"

# Cleanup temp files
rm -f $TMPDIR/submit_lambda.py $TMPDIR/submit_lambda.zip \
       $TMPDIR/processor_lambda.py $TMPDIR/processor_lambda.zip \
       $TMPDIR/index.html

# ── Final Summary ─────────────────────────────────────────────
echo ""
echo -e "${BOLD}${GREEN}============================================================${NC}"
echo -e "${BOLD}${GREEN}   Deployment Complete! ✓${NC}"
echo -e "${BOLD}${GREEN}============================================================${NC}"
echo ""
echo -e "  ${BOLD}Project:${NC}              $PROJECT_NAME"
echo -e "  ${BOLD}S3 Website URL:${NC}       ${CYAN}$S3_WEBSITE_URL${NC}"
echo -e "  ${BOLD}API Endpoint:${NC}         $API_ENDPOINT"
echo ""
echo -e "  ${BOLD}Amazon Cognito:${NC}"
echo -e "    User Pool Name  : $COGNITO_POOL_NAME"
echo -e "    User Pool ID    : ${CYAN}$USER_POOL_ID${NC}"
echo -e "    App Client ID   : ${CYAN}$APP_CLIENT_ID${NC}"
echo -e "    Test Username   : ${CYAN}$USERNAME${NC}"
echo -e "    Test Password   : ${CYAN}$PASSWORD${NC}"
echo -e "    Groups          : $GROUP1, $GROUP2"
echo -e "    Auth Test       : PASSED ✓"
echo ""
echo -e "  ${BOLD}AWS Resources:${NC}"
echo -e "    DynamoDB        : $TABLE_NAME, $TICKETS_TABLE"
echo -e "    SQS Main Queue  : $MAIN_QUEUE_NAME"
echo -e "    SQS DLQ         : $DLQ_NAME"
echo -e "    SNS Topic       : $SNS_TOPIC_NAME"
echo -e "    Submit Lambda   : $SUBMIT_LAMBDA_NAME"
echo -e "    Processor Lambda: $PROCESSOR_LAMBDA_NAME"
echo -e "    Deployed at     : $TIMESTAMP_NOW"
echo ""
echo -e "${YELLOW}  [!] Confirm the SNS subscription email sent to: $SNS_EMAIL${NC}"
echo ""
echo -e "${GREEN}  Open your website:${NC}"
echo -e "  ${CYAN}$S3_WEBSITE_URL${NC}"
echo ""