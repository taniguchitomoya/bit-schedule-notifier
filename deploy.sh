#!/usr/bin/env bash
set -e

# Configuration
FUNCTION_NAME="bitschedule-notifier"
RULE_NAME="bitschedule-daily-trigger"
ROLE_NAME="bitschedule-lambda-role"
ZIP_FILE="lambda.zip"
CSV_FILE="schedule_dates.csv"
LAMBDA_FILE="lambda_function.py"

# 1. Check if Lambda function exists
FUNCTION_EXISTS=$(aws lambda get-function --function-name "$FUNCTION_NAME" --query "Configuration.FunctionArn" --output text 2>/dev/null || true)

# 2. Resolve Discord Webhook URL if provided
if [ -n "$1" ]; then
    DISCORD_WEBHOOK_URL="$1"
fi

if [ -z "$FUNCTION_EXISTS" ] && [ -z "$DISCORD_WEBHOOK_URL" ]; then
    echo "Error: DISCORD_WEBHOOK_URL is required to create a new Lambda function."
    echo "Usage: ./deploy.sh <YOUR_DISCORD_WEBHOOK_URL>"
    echo "Or set the environment variable: export DISCORD_WEBHOOK_URL='<YOUR_URL>'"
    exit 1
fi

echo "=== Starting deployment for $FUNCTION_NAME ==="

# 2. Check dependencies
if [ ! -f "$LAMBDA_FILE" ]; then
    echo "Error: $LAMBDA_FILE not found in the current directory."
    exit 1
fi
if [ ! -f "$CSV_FILE" ]; then
    echo "Error: $CSV_FILE not found in the current directory."
    exit 1
fi

# 3. Setup IAM Role
echo "Setting up IAM execution role..."
ROLE_ARN=""

# Check if role already exists
EXISTING_ROLE_ARN=$(aws iam get-role --role-name "$ROLE_NAME" --query "Role.Arn" --output text 2>/dev/null || true)

if [ -n "$EXISTING_ROLE_ARN" ]; then
    echo "Using existing IAM role: $ROLE_NAME"
    ROLE_ARN="$EXISTING_ROLE_ARN"
else
    # Try to create new role
    echo "Creating new IAM role: $ROLE_NAME..."
    cat <<EOF > trust-policy.json
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Effect": "Allow",
      "Principal": {
        "Service": "lambda.amazonaws.com"
      },
      "Action": "sts:AssumeRole"
    }
  ]
}
EOF

    if ROLE_ARN=$(aws iam create-role --role-name "$ROLE_NAME" --assume-role-policy-document file://trust-policy.json --query "Role.Arn" --output text 2>/dev/null); then
        echo "Role created successfully. Attaching BasicExecutionRole policy..."
        aws iam attach-role-policy --role-name "$ROLE_NAME" --policy-arn arn:aws:iam::aws:policy/service-role/AWSLambdaBasicExecutionRole
        rm trust-policy.json
        echo "Waiting 10 seconds for IAM role propagation..."
        sleep 10
    else
        echo "WARNING: Failed to create IAM role '$ROLE_NAME' (likely due to insufficient permissions)."
        rm -f trust-policy.json
        
        # Check if AWS_ROLE_ARN is provided via environment variable
        if [ -n "$AWS_ROLE_ARN" ]; then
            echo "Using provided AWS_ROLE_ARN: $AWS_ROLE_ARN"
            ROLE_ARN="$AWS_ROLE_ARN"
        else
            echo "Error: Could not create a new IAM role."
            echo "If you have an existing execution role, please specify it via the AWS_ROLE_ARN environment variable."
            echo "Example: export AWS_ROLE_ARN='arn:aws:iam::123456789012:role/your-lambda-role'"
            exit 1
        fi
    fi
fi

# 4. Create deployment package
echo "Packaging lambda code and CSV..."
rm -f "$ZIP_FILE"
zip -q "$ZIP_FILE" "$LAMBDA_FILE" "$CSV_FILE"
echo "Package created: $ZIP_FILE"

# 5. Deploy / Update Lambda Function
echo "Deploying Lambda function..."

if [ -z "$FUNCTION_EXISTS" ]; then
    echo "Creating new Lambda function: $FUNCTION_NAME..."
    aws lambda create-function \
        --function-name "$FUNCTION_NAME" \
        --runtime python3.11 \
        --role "$ROLE_ARN" \
        --handler lambda_function.lambda_handler \
        --zip-file fileb://"$ZIP_FILE" \
        --timeout 30 \
        --environment "Variables={DISCORD_WEBHOOK_URL=$DISCORD_WEBHOOK_URL}"
    echo "Lambda function created successfully."
else
    echo "Lambda function already exists. Updating function code..."
    aws lambda update-function-code \
        --function-name "$FUNCTION_NAME" \
        --zip-file fileb://"$ZIP_FILE"
        
    if [ -n "$DISCORD_WEBHOOK_URL" ]; then
        echo "Waiting for function code update to complete..."
        aws lambda wait function-updated --function-name "$FUNCTION_NAME"
        
        echo "Updating environment variables and configuration..."
        aws lambda update-function-configuration \
            --function-name "$FUNCTION_NAME" \
            --environment "Variables={DISCORD_WEBHOOK_URL=$DISCORD_WEBHOOK_URL}" \
            --timeout 30
        echo "Lambda function configuration updated successfully."
    else
        echo "No new DISCORD_WEBHOOK_URL provided. Keeping existing Lambda configuration."
    fi
fi

# 6. Configure EventBridge rule (Weekday trigger at 9:10 AM JST / 0:10 UTC until next year)
CURRENT_YEAR=$(date +%Y)
NEXT_YEAR=$((CURRENT_YEAR + 1))
CRON_EXPR="cron(10 0 ? * MON-FRI ${CURRENT_YEAR}-${NEXT_YEAR})"
echo "Setting up EventBridge Rule (Trigger: Weekdays at 9:10 JST / 0:10 UTC, Year: ${CURRENT_YEAR}-${NEXT_YEAR})..."
echo "Cron expression: $CRON_EXPR"

RULE_ARN=$(aws events put-rule \
    --name "$RULE_NAME" \
    --schedule-expression "$CRON_EXPR" \
    --state ENABLED \
    --query "RuleArn" \
    --output text)

echo "Adding Lambda invocation permission for EventBridge..."
aws lambda add-permission \
    --function-name "$FUNCTION_NAME" \
    --statement-id "EventBridgeDailyTrigger" \
    --action lambda:InvokeFunction \
    --principal events.amazonaws.com \
    --source-arn "$RULE_ARN" \
    2>/dev/null || true

# Link target
LAMBDA_ARN=$(aws lambda get-function --function-name "$FUNCTION_NAME" --query "Configuration.FunctionArn" --output text)
echo "Adding target to EventBridge rule..."
aws events put-targets \
    --rule "$RULE_NAME" \
    --targets "Id=1,Arn=$LAMBDA_ARN"

# Clean up local zip
rm -f "$ZIP_FILE"

echo "=== Deployment Finished Successfully ==="
echo "Lambda Function Name: $FUNCTION_NAME"
echo "Role ARN: $ROLE_ARN"
echo "EventBridge Rule Name: $RULE_NAME"
echo ""
echo "To test the Lambda function immediately, run the following command:"
echo "aws lambda invoke --function-name $FUNCTION_NAME --payload '{}' response.json && cat response.json && rm response.json"
