#!/usr/bin/env bash
set -e

# Configuration
SCRAPER_FUNCTION_NAME="bitschedule-scraper"
NOTIFIER_FUNCTION_NAME="bitschedule-notifier"
ROLE_NAME="bitschedule-lambda-role"
SCRAPER_RULE_NAME="bitschedule-scraper-trigger"
NOTIFIER_RULE_NAME="bitschedule-notifier-trigger"

# Input arguments
DISCORD_WEBHOOK_URL="$1"
S3_BUCKET_NAME="$2"
DEV_DISCORD_WEBHOOK_URL="$3"

# 1. Resolve arguments / env variables
if [ -z "$DISCORD_WEBHOOK_URL" ] && [ -n "$DISCORD_WEBHOOK_URL_ENV" ]; then
    DISCORD_WEBHOOK_URL="$DISCORD_WEBHOOK_URL_ENV"
fi

if [ -z "$DEV_DISCORD_WEBHOOK_URL" ] && [ -n "$DEV_DISCORD_WEBHOOK_URL_ENV" ]; then
    DEV_DISCORD_WEBHOOK_URL="$DEV_DISCORD_WEBHOOK_URL_ENV"
fi

# Ensure Discord URL is set (for notifier function creation/configuration)
if [ -z "$DISCORD_WEBHOOK_URL" ]; then
    # We only error out if functions don't exist yet
    SCRAPER_EXISTS=$(aws lambda get-function --function-name "$SCRAPER_FUNCTION_NAME" --query "Configuration.FunctionArn" --output text 2>/dev/null || true)
    NOTIFIER_EXISTS=$(aws lambda get-function --function-name "$NOTIFIER_FUNCTION_NAME" --query "Configuration.FunctionArn" --output text 2>/dev/null || true)
    if [ -z "$SCRAPER_EXISTS" ] || [ -z "$NOTIFIER_EXISTS" ]; then
        echo "Error: DISCORD_WEBHOOK_URL is required for initial deployment."
        echo "Usage: ./deploy.sh <YOUR_DISCORD_WEBHOOK_URL> [OPTIONAL_S3_BUCKET_NAME] [DEV_DISCORD_WEBHOOK_URL]"
        exit 1
    fi
fi

# Get AWS Account ID to generate bucket name if not provided
AWS_ACCOUNT_ID=$(aws sts get-caller-identity --query "Account" --output text 2>/dev/null || true)
if [ -z "$AWS_ACCOUNT_ID" ]; then
    echo "Error: Failed to retrieve AWS Account ID. Please ensure your AWS CLI is configured correctly."
    exit 1
fi

if [ -z "$S3_BUCKET_NAME" ]; then
    S3_BUCKET_NAME="bitschedule-data-${AWS_ACCOUNT_ID}"
    echo "No S3 Bucket specified. Automatically using bucket name: $S3_BUCKET_NAME"
fi

REGION=$(aws configure get region || echo "ap-northeast-1")
echo "=== Deploying to region: $REGION ==="

# 2. Clean up legacy configurations from previous single-lambda version if they exist
echo "Checking for legacy EventBridge configurations..."
OLD_RULE_EXISTS=$(aws events describe-rule --name "bitschedule-daily-trigger" --query "Name" --output text 2>/dev/null || true)
if [ -n "$OLD_RULE_EXISTS" ] && [ "$OLD_RULE_EXISTS" != "None" ]; then
    echo "Found legacy configuration: bitschedule-daily-trigger"
    echo "Removing targets from legacy rule..."
    aws events remove-targets --rule "bitschedule-daily-trigger" --ids "1" 2>/dev/null || true
    
    echo "Deleting legacy rule..."
    aws events delete-rule --name "bitschedule-daily-trigger" 2>/dev/null || true
    
    echo "Removing legacy Lambda permission 'EventBridgeDailyTrigger'..."
    aws lambda remove-permission \
        --function-name "$NOTIFIER_FUNCTION_NAME" \
        --statement-id "EventBridgeDailyTrigger" \
        2>/dev/null || true
    echo "Legacy configurations cleaned up successfully."
fi

# 3. Create S3 Bucket if it doesn't exist
echo "Checking S3 bucket '$S3_BUCKET_NAME'..."
if aws s3api head-bucket --bucket "$S3_BUCKET_NAME" 2>/dev/null; then
    echo "S3 bucket already exists."
else
    echo "S3 bucket does not exist. Creating bucket: $S3_BUCKET_NAME..."
    if [ "$REGION" = "us-east-1" ]; then
        aws s3api create-bucket --bucket "$S3_BUCKET_NAME" --region "$REGION"
    else
        aws s3api create-bucket --bucket "$S3_BUCKET_NAME" --region "$REGION" \
            --create-bucket-configuration LocationConstraint="$REGION"
    fi
    echo "S3 bucket created successfully."
fi

# 4. Setup IAM Role
echo "Setting up IAM execution role..."
ROLE_ARN=""
EXISTING_ROLE_ARN=$(aws iam get-role --role-name "$ROLE_NAME" --query "Role.Arn" --output text 2>/dev/null || true)

if [ -n "$EXISTING_ROLE_ARN" ]; then
    echo "Using existing IAM role: $ROLE_NAME"
    ROLE_ARN="$EXISTING_ROLE_ARN"
else
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
    ROLE_ARN=$(aws iam create-role --role-name "$ROLE_NAME" --assume-role-policy-document file://trust-policy.json --query "Role.Arn" --output text)
    rm -f trust-policy.json
    
    echo "Attaching AWSLambdaBasicExecutionRole policy..."
    aws iam attach-role-policy --role-name "$ROLE_NAME" --policy-arn arn:aws:iam::aws:policy/service-role/AWSLambdaBasicExecutionRole
    
    echo "Attaching S3 permissions to the new IAM role..."
    cat <<EOF > s3-policy.json
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Effect": "Allow",
      "Action": [
        "s3:PutObject",
        "s3:GetObject"
      ],
      "Resource": "arn:aws:s3:::${S3_BUCKET_NAME}/*"
    }
  ]
}
EOF
    aws iam put-role-policy \
        --role-name "$ROLE_NAME" \
        --policy-name "bitschedule-s3-policy" \
        --policy-document file://s3-policy.json
    rm -f s3-policy.json

    echo "Waiting 10 seconds for IAM role propagation..."
    sleep 10
fi

# 5. Build and Deploy Scraper Lambda
echo "=== Building and Deploying Scraper Lambda ==="
rm -rf build_scraper scraper.zip
mkdir -p build_scraper

# Install scraper dependencies
if [ -f "requirements.txt" ]; then
    echo "Installing requirements for scraper..."
    pip install -q -r requirements.txt -t build_scraper/
fi
cp lambda_scraper.py build_scraper/lambda_function.py

# Create zip
cd build_scraper
zip -q -r ../scraper.zip .
cd ..
rm -rf build_scraper
echo "Scraper package created: scraper.zip"

# Deploy function
# Build environment variables for Scraper
SCRAPER_ENV_VARS="S3_BUCKET=${S3_BUCKET_NAME},S3_KEY=schedule_dates.csv"
if [ -n "$DEV_DISCORD_WEBHOOK_URL" ] && [ "$DEV_DISCORD_WEBHOOK_URL" != "None" ]; then
    SCRAPER_ENV_VARS="${SCRAPER_ENV_VARS},DEV_DISCORD_WEBHOOK_URL=${DEV_DISCORD_WEBHOOK_URL}"
fi

SCRAPER_EXISTS=$(aws lambda get-function --function-name "$SCRAPER_FUNCTION_NAME" --query "Configuration.FunctionArn" --output text 2>/dev/null || true)
if [ -z "$SCRAPER_EXISTS" ]; then
    echo "Creating Scraper Lambda function..."
    aws lambda create-function \
        --function-name "$SCRAPER_FUNCTION_NAME" \
        --runtime python3.11 \
        --role "$ROLE_ARN" \
        --handler lambda_function.lambda_handler \
        --zip-file fileb://scraper.zip \
        --timeout 300 \
        --memory-size 256 \
        --environment "Variables={${SCRAPER_ENV_VARS}}"
    echo "Scraper Lambda created."
else
    echo "Scraper Lambda already exists. Updating code..."
    aws lambda update-function-code \
        --function-name "$SCRAPER_FUNCTION_NAME" \
        --zip-file fileb://scraper.zip
        
    echo "Waiting for Scraper Lambda code update to complete..."
    aws lambda wait function-updated --function-name "$SCRAPER_FUNCTION_NAME"
    
    echo "Updating Scraper configuration..."
    # Resolve DEV_DISCORD_WEBHOOK_URL: prioritize passed value, then existing DEV_DISCORD_WEBHOOK_URL, then fallback to existing DISCORD_WEBHOOK_URL
    CURRENT_DEV_WEBHOOK="$DEV_DISCORD_WEBHOOK_URL"
    if [ -z "$CURRENT_DEV_WEBHOOK" ]; then
        EXISTING_DEV_WEBHOOK=$(aws lambda get-function-configuration --function-name "$SCRAPER_FUNCTION_NAME" --query "Environment.Variables.DEV_DISCORD_WEBHOOK_URL" --output text 2>/dev/null || echo "")
        if [ "$EXISTING_DEV_WEBHOOK" != "None" ] && [ -n "$EXISTING_DEV_WEBHOOK" ]; then
            CURRENT_DEV_WEBHOOK="$EXISTING_DEV_WEBHOOK"
        else
            EXISTING_OLD_WEBHOOK=$(aws lambda get-function-configuration --function-name "$SCRAPER_FUNCTION_NAME" --query "Environment.Variables.DISCORD_WEBHOOK_URL" --output text 2>/dev/null || echo "")
            if [ "$EXISTING_OLD_WEBHOOK" != "None" ] && [ -n "$EXISTING_OLD_WEBHOOK" ]; then
                CURRENT_DEV_WEBHOOK="$EXISTING_OLD_WEBHOOK"
            fi
        fi
    fi

    SCRAPER_ENV_VARS="S3_BUCKET=${S3_BUCKET_NAME},S3_KEY=schedule_dates.csv"
    if [ -n "$CURRENT_DEV_WEBHOOK" ] && [ "$CURRENT_DEV_WEBHOOK" != "None" ]; then
        SCRAPER_ENV_VARS="${SCRAPER_ENV_VARS},DEV_DISCORD_WEBHOOK_URL=${CURRENT_DEV_WEBHOOK}"
    fi

    aws lambda update-function-configuration \
        --function-name "$SCRAPER_FUNCTION_NAME" \
        --timeout 300 \
        --memory-size 256 \
        --environment "Variables={${SCRAPER_ENV_VARS}}"
    echo "Scraper Lambda configuration updated."
fi
rm -f scraper.zip

# 6. Build and Deploy Notifier Lambda
echo "=== Building and Deploying Notifier Lambda ==="
rm -rf build_notifier notifier.zip
mkdir -p build_notifier
cp lambda_notifier.py build_notifier/lambda_function.py

cd build_notifier
zip -q -r ../notifier.zip .
cd ..
rm -rf build_notifier
echo "Notifier package created: notifier.zip"

    NOTIFIER_ENV_VARS="S3_BUCKET=${S3_BUCKET_NAME},S3_KEY=schedule_dates.csv"
    if [ -n "$DISCORD_WEBHOOK_URL" ] && [ "$DISCORD_WEBHOOK_URL" != "None" ]; then
        NOTIFIER_ENV_VARS="${NOTIFIER_ENV_VARS},DISCORD_WEBHOOK_URL=${DISCORD_WEBHOOK_URL}"
    fi

    NOTIFIER_EXISTS=$(aws lambda get-function --function-name "$NOTIFIER_FUNCTION_NAME" --query "Configuration.FunctionArn" --output text 2>/dev/null || true)
    if [ -z "$NOTIFIER_EXISTS" ]; then
        echo "Creating Notifier Lambda function..."
        aws lambda create-function \
            --function-name "$NOTIFIER_FUNCTION_NAME" \
            --runtime python3.11 \
            --role "$ROLE_ARN" \
            --handler lambda_function.lambda_handler \
            --zip-file fileb://notifier.zip \
            --timeout 30 \
            --environment "Variables={${NOTIFIER_ENV_VARS}}"
        echo "Notifier Lambda created."
    else
        echo "Notifier Lambda already exists. Updating code..."
        aws lambda update-function-code \
            --function-name "$NOTIFIER_FUNCTION_NAME" \
            --zip-file fileb://notifier.zip
            
        echo "Waiting for Notifier Lambda code update to complete..."
        aws lambda wait function-updated --function-name "$NOTIFIER_FUNCTION_NAME"
        
        echo "Updating Notifier configuration..."
        CURRENT_NOTIFIER_WEBHOOK="$DISCORD_WEBHOOK_URL"
        if [ -z "$CURRENT_NOTIFIER_WEBHOOK" ]; then
            EXISTING_WEBHOOK=$(aws lambda get-function-configuration --function-name "$NOTIFIER_FUNCTION_NAME" --query "Environment.Variables.DISCORD_WEBHOOK_URL" --output text 2>/dev/null || echo "")
            if [ "$EXISTING_WEBHOOK" != "None" ]; then
                CURRENT_NOTIFIER_WEBHOOK="$EXISTING_WEBHOOK"
            fi
        fi

        NOTIFIER_ENV_VARS="S3_BUCKET=${S3_BUCKET_NAME},S3_KEY=schedule_dates.csv"
        if [ -n "$CURRENT_NOTIFIER_WEBHOOK" ] && [ "$CURRENT_NOTIFIER_WEBHOOK" != "None" ]; then
            NOTIFIER_ENV_VARS="${NOTIFIER_ENV_VARS},DISCORD_WEBHOOK_URL=${CURRENT_NOTIFIER_WEBHOOK}"
        fi

        aws lambda update-function-configuration \
            --function-name "$NOTIFIER_FUNCTION_NAME" \
            --timeout 30 \
            --environment "Variables={${NOTIFIER_ENV_VARS}}"
        echo "Notifier Lambda configuration updated."
    fi
rm -f notifier.zip

# 7. Configure EventBridge Triggers
echo "=== Setting up EventBridge Triggers ==="

# Scraper Rule: Weekly at 8:40 AM JST on Monday (23:40 UTC on Sunday)
SCRAPER_CRON="cron(40 23 ? * SUN *)"
echo "Creating Scraper Trigger: $SCRAPER_CRON..."
SCRAPER_RULE_ARN=$(aws events put-rule \
    --name "$SCRAPER_RULE_NAME" \
    --schedule-expression "$SCRAPER_CRON" \
    --state ENABLED \
    --query "RuleArn" \
    --output text)

aws lambda add-permission \
    --function-name "$SCRAPER_FUNCTION_NAME" \
    --statement-id "EventBridgeScraperTrigger" \
    --action lambda:InvokeFunction \
    --principal events.amazonaws.com \
    --source-arn "$SCRAPER_RULE_ARN" \
    2>/dev/null || true

SCRAPER_LAMBDA_ARN=$(aws lambda get-function --function-name "$SCRAPER_FUNCTION_NAME" --query "Configuration.FunctionArn" --output text)
aws events put-targets \
    --rule "$SCRAPER_RULE_NAME" \
    --targets "Id=1,Arn=$SCRAPER_LAMBDA_ARN"

# Notifier Rule: Weekdays at 9:10 AM JST (0:10 UTC)
NOTIFIER_CRON="cron(10 0 ? * MON-FRI *)"
echo "Creating Notifier Trigger: $NOTIFIER_CRON..."
NOTIFIER_RULE_ARN=$(aws events put-rule \
    --name "$NOTIFIER_RULE_NAME" \
    --schedule-expression "$NOTIFIER_CRON" \
    --state ENABLED \
    --query "RuleArn" \
    --output text)

aws lambda add-permission \
    --function-name "$NOTIFIER_FUNCTION_NAME" \
    --statement-id "EventBridgeNotifierTrigger" \
    --action lambda:InvokeFunction \
    --principal events.amazonaws.com \
    --source-arn "$NOTIFIER_RULE_ARN" \
    2>/dev/null || true

NOTIFIER_LAMBDA_ARN=$(aws lambda get-function --function-name "$NOTIFIER_FUNCTION_NAME" --query "Configuration.FunctionArn" --output text)
aws events put-targets \
    --rule "$NOTIFIER_RULE_NAME" \
    --targets "Id=1,Arn=$NOTIFIER_LAMBDA_ARN"

echo "=== Deployment Finished Successfully ==="
echo "S3 Bucket: $S3_BUCKET_NAME"
echo "Scraper Lambda: $SCRAPER_FUNCTION_NAME"
echo "Notifier Lambda: $NOTIFIER_FUNCTION_NAME"
echo "Scraper Trigger: Weekly at 8:40 AM JST on Monday"
echo "Notifier Trigger: Weekdays at 9:10 AM JST"
echo ""
echo "To trigger the scraper manually and fetch the latest schedule (Wait with 5 min timeout):"
echo "aws lambda invoke --function-name $SCRAPER_FUNCTION_NAME --cli-read-timeout 300 response_scraper.json && cat response_scraper.json && rm response_scraper.json"
echo ""
echo "To test notifier immediately after scraper finishes:"
echo "aws lambda invoke --function-name $NOTIFIER_FUNCTION_NAME response_notifier.json && cat response_notifier.json && rm response_notifier.json"
