
# 1. copy git files to S3 bucket
aws s3 cp 's3://s3-eu-central-1.amazonaws.com/dynaknot/' . || error_exit 'Failed to download AWS CodeDeploy Agent.'

# 2. create immagebuilder pipeline
#quickstart-sap-hana/dynaknot/imagebuilder/create-pipeline-goldenami-ubuntu18.sh

