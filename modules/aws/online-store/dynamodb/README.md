This is the configuration for an AWS DynamoDB table used as an online store for chalk.
It includes autoscaling configurations, and a secret stored in AWS Secrets Manager for accessing the table.
To integrate this table with your chalk deployment, apply this terraform in the same account as your chalk instance,
and set the `online_store_secret` in Integrations > Online Store > DynamoDB to the secret created by this module.