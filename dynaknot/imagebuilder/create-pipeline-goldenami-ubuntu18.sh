aws imagebuilder create-component \
    --cli-input-json file://quickstart-sap-hana/dynaknot/components/create-component-update-ubuntu.json

# get component id
#aws imagebuilder list-components
#aws iam list-users --output text --query 'Users[*].[UserName,Arn,CreateDate,PasswordLastUsed,UserId]'
#aws imagebuilder list-components --output text --query 'Users[*].[UserName,Arn,CreateDate,PasswordLastUsed,UserId]'
#aws imagebuilder get-component \
#    --component-build-version-arn arn:aws:imagebuilder:us-west-2:123456789012:component/component-name/1.0.0/1

# create recipe
#aws imagebuilder create-image-recipe \
#    --cli-input-json file://create-image-recipe.json

# get recipe id
#aws imagebuilder get-image-recipe
#--image-recipe-arn <value>
#[--cli-input-json <value>]
#[--generate-cli-skeleton <value>]

# create pipeline
#aws imagebuilder create-image-pipeline \
#    --cli-input-json file://create-image-pipeline.json

# get pipeline id
#aws imagebuilder get-image-pipeline \
#    --image-pipeline-arn arn:aws:imagebuilder:us-west-2:123456789012:image-pipeline/mywindows2016pipeline

# create image
#aws imagebuilder create-image \
#    --image-recipe-arn arn:aws:imagebuilder:us-west-2:123456789012:image-recipe/mybasicrecipe/2019.12.03 \
#    --infrastructure-configuration-arn arn:aws:imagebuilder:us-west-2:123456789012:infrastructure-configuration/myexampleinfrastructure

#aws imagebuilder get-image \
#    --image-build-version-arn arn:aws:imagebuilder:us-west-2:123456789012:image/mybasicrecipe/2019.12.03/1

#aws imagebuilder list-images
