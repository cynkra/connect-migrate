#!/usr/bin/env bash

APP_NAME=$1

echo -e "#------- Processing app '$APP_NAME' -------#"

# get various information from old app ----------------------------------------#
GUID_OLD=$(curl --silent --show-error -L --max-redirs 0 --fail \
	-X GET \
	-H "Authorization: Key ${API_KEY_OLD}" \
	"${RSC_OLD}/__api__/v1/content?page_size=500" | jq --arg APP_NAME "$APP_NAME" -r '.[] | select(.name==$APP_NAME) | .guid')
R_VERSION=$(curl --silent --show-error -L --max-redirs 0 --fail \
	-X GET \
	-H "Authorization: Key ${API_KEY_OLD}" \
	"${RSC_OLD}/__api__/v1/content/${GUID_OLD}" | jq -r '.r_version')
BUNDLE_ID=$(curl --silent --show-error -L --max-redirs 0 --fail \
	-X GET \
	-H "Authorization: Key ${API_KEY_OLD}" \
	"${RSC_OLD}/__api__/v1/content/${GUID_OLD}" | jq -r '.bundle_id')
# get GUID of admin user for old RSC
GUID_ADMIN_OLD=$(curl --silent --show-error -L --max-redirs 0 --fail \
	-X GET \
	-H "Authorization: Key ${API_KEY_OLD}" \
	"${RSC_OLD}/__api__/v1/users" | jq --arg ADMIN_OLD "$ADMIN_OLD" -r '.results[] | select(.username==$ADMIN_OLD) | .guid')
# get GUID of new content
GUID_NEW=$(curl --silent --show-error -L --max-redirs 0 --fail \
	-X GET \
	-H "Authorization: Key ${API_KEY_NEW}" \
	"${RSC_NEW}/__api__/v1/content" | jq --arg APP_NAME "$APP_NAME" -r '.[] | select(.name==$APP_NAME) | .guid')
# get GUID of old owner
GUID_OWNER_OLD=$(curl --silent --show-error -L --max-redirs 0 --fail \
	-X GET \
	-H "Authorization: Key ${API_KEY_OLD}" \
	"${RSC_OLD}/__api__/v1/content" | jq --arg APP_NAME "$APP_NAME" -r '.[] | select(.name==$APP_NAME) | .owner_guid')

# restore tag schema ----------------------------------------------------------#

if [[ $RESTORE_TAG_SCHEMA == "true" ]]; then
	echo -e "STEP: Restoring tag schema"

	TAGS_OLD=$(curl --silent --show-error -L --max-redirs 0 --fail \
		-X GET \
		-H "Authorization: Key ${API_KEY_OLD}" \
		"${RSC_OLD}/__api__/v1/tags" | jq -r '.[] | .name')

	for TAG in $TAGS_OLD; do

		ALL_TAGS_NEW=$(curl --silent --show-error -L --max-redirs 0 --fail \
			-X GET \
			-H "Authorization: Key ${API_KEY_NEW}" \
			"${RSC_NEW}/__api__/v1/tags" | jq -r '.[] | .name' | grep -q $TAG && echo "true" || echo "false")
		if [ "$ALL_TAGS_NEW" == "true" ]; then
			echo -e "INFO: Skipping creation of tag '$TAG' because it already exists in the new RSC instance"
			continue
		fi

		# get parent_id of tag
		# TAG=type
		TAG_PARENT_ID_OLD=$(curl --silent --show-error -L --max-redirs 0 --fail \
			-X GET \
			-H "Authorization: Key ${API_KEY_OLD}" \
			"${RSC_OLD}/__api__/v1/tags" | jq --arg TAG "$TAG" '.[] | select(.name==$TAG) | .parent_id')

		# if TAG is not a top-level tag, we need to query the ID of the new parent tag
		if [[ $TAG_PARENT_ID_OLD != "null" ]]; then

			# we need unquoted input here to make the API call work
			TAG_PARENT_ID_OLD=$(eval echo $TAG_PARENT_ID_OLD)

			TAG_PARENT_NAME_OLD=$(curl --silent --show-error -L --max-redirs 0 --fail \
				-X GET \
				-H "Authorization: Key ${API_KEY_OLD}" \
				"${RSC_OLD}/__api__/v1/tags" | jq -r --arg TAG_PARENT_ID_OLD "$TAG_PARENT_ID_OLD" '.[] | select(.id==$TAG_PARENT_ID_OLD) | .name')

			TAG_PARENT_ID_NEW=$(curl --silent --show-error -L --max-redirs 0 --fail \
				-X GET \
				-H "Authorization: Key ${API_KEY_NEW}" \
				"${RSC_NEW}/__api__/v1/tags" | jq --arg TAG_PARENT_NAME_OLD "$TAG_PARENT_NAME_OLD" '.[] | select(.name==$TAG_PARENT_NAME_OLD) | .id')

		else
			TAG_PARENT_ID_NEW=$TAG_PARENT_ID_OLD
		fi

		echo -e "Creating tag '$TAG'"
		# echo -e "$TAG_PARENT_ID_OLD"

		DATA="{
          \"name\": \"${TAG}\",
          \"parent_id\": ${TAG_PARENT_ID_NEW}
           }"

		curl --silent --show-error -L --max-redirs 0 --fail \
			-X POST \
			-H "Authorization: Key ${API_KEY_NEW}" \
			--data-raw "${DATA}" \
			"${RSC_NEW}/__api__/v1/tags" >/dev/null
	done
fi

# skip if app already exists and exit if so ---------------------------------#
ALL_APPS_NEW=$(curl --silent --show-error -L --max-redirs 0 --fail \
	-X GET \
	-H "Authorization: Key ${API_KEY_NEW}" \
	"${RSC_NEW}/__api__/v1/content" | jq -r '.[] | .name' | grep -q $APP_NAME && echo "true" || echo "false")

if [ "$ALL_APPS_NEW" == "true" ]; then
	echo -e "INFO: Skipping transfer of app '$APP_NAME' because it already exists in the new RSC instance"
fi

if [[ $REBUILD_CONTENT == "true" && $ALL_APPS_NEW == "false" ]]; then

	# to download bundles, one must be a collab of the app
	DATA="{
  \"principal_guid\": \"${GUID_ADMIN_OLD}\",
  \"principal_type\": \"user\",
  \"role\": \"owner\"
}"

	curl --silent -L --max-redirs 0 --fail \
		-X POST \
		-H "Authorization: Key ${API_KEY_OLD}" \
		--data-raw "${DATA}" \
		"${RSC_OLD}/__api__/v1/content/${GUID_OLD}/permissions" >/dev/null

	# download bundle and restore app -------------------------------------------#
	mkdir migrate-${APP_NAME}
	cd migrate-${APP_NAME}

	curl --silent --show-error -L -k --max-redirs 0 --fail \
		-H "Authorization: Key ${API_KEY_OLD}" \
		"${RSC_OLD}/__api__/v1/content/${GUID_OLD}/bundles/${BUNDLE_ID}/download" | tar xz

	# some apps have the R versin not stored in its content, so we need to read it from the manifest.json
	if [[ $R_VERSION == "null" ]]; then
		R_VERSION=$(cat manifest.json | grep "platform" | grep "[0-9]\.[0-9]\.[0-9]" -o)
	fi

	# need to unset these vars which are set by RSW to get the correct user lib location
	unset R_HOME R_LIBS_SITE R_LIBS_USER && /opt/R/${R_VERSION}/bin/R -q -e 'if(!requireNamespace("packrat")) install.packages("packrat", repos = "cloud.r-project.org")'
	unset R_HOME R_LIBS_SITE R_LIBS_USER && /opt/R/${R_VERSION}/bin/R -q -e 'if(!requireNamespace("rsconnect")) install.packages("rsconnect")'
	unset R_HOME R_LIBS_SITE R_LIBS_USER && /opt/R/${R_VERSION}/bin/R -q -e 'if(!requireNamespace("curl")) install.packages("curl")'
	unset R_HOME R_LIBS_SITE R_LIBS_USER && /opt/R/${R_VERSION}/bin/R -q -e 'if(!requireNamespace("jsonlite")) install.packages("jsonlite")'

	unset R_HOME R_LIBS_SITE R_LIBS_USER && /opt/R/${R_VERSION}/bin/R -q -e "rsconnect::addConnectServer('${RSC_NEW}', '${SERVER_NAME_NEW}', quiet = T)"
	unset R_HOME R_LIBS_SITE R_LIBS_USER && /opt/R/${R_VERSION}/bin/R -q -e "rsconnect::connectApiUser(server = '${SERVER_NAME_NEW}', apiKey = '${API_KEY_NEW}', account = '${USER_NEW}', quiet = TRUE)"

	# we only need to call restore for apps which are not of type 'static'
	if cat manifest.json | grep -q "appmode\": \"static\""; then
		echo -e "Skipping packrat restore for static app '${APP_NAME}'"
		unset R_HOME R_LIBS_SITE R_LIBS_USER && /opt/R/${R_VERSION}/bin/R -q -e "rsconnect::deployApp(appName = '${APP_NAME}', server = '${SERVER_NAME_NEW}', account = '${USER_NEW}', logLevel = 'verbose')"
	else
		echo -e "Restoring packrat environment for app '$APP_NAME'"
		unset R_HOME R_LIBS_SITE R_LIBS_USER && /opt/R/${R_VERSION}/bin/R -q -e 'packrat::restore()'
		unset R_HOME R_LIBS_SITE R_LIBS_USER && /opt/R/${R_VERSION}/bin/R -q -e "packrat::on(); packrat::extlib(c('rsconnect', 'curl', 'jsonlite')); rsconnect::deployApp(appName = '${APP_NAME}', server = '${SERVER_NAME_NEW}', account = '${USER_NEW}', logLevel = 'verbose')"
	fi

	# restore owner ---------------------------------------------------------------#

	# get name of old owner
	NAME_OWNER_OLD=$(curl --silent --show-error -L --max-redirs 0 --fail \
		-X GET \
		-H "Authorization: Key ${API_KEY_OLD}" \
		"${RSC_OLD}/__api__/v1/users" | jq --arg GUID_OWNER_OLD "$GUID_OWNER_OLD" -r '.results[] | select(.guid==$GUID_OWNER_OLD) | .username')

	# create account of new owner
	DATA="{
  \"email\": \"${NAME_OWNER_OLD}@cynkra.com\",
  \"username\": \"${NAME_OWNER_OLD}\",
  \"unique_id\": \"${NAME_OWNER_OLD}\"
}"

	curl --silent --show-error -L --max-redirs 0 --fail \
		-X POST \
		-H "Authorization: Key ${API_KEY_NEW}" \
		--data-raw "${DATA}" \
		"${RSC_NEW}/__api__/v1/users" >/dev/null

	# get GUID of new owner
	OWNER_GUID_NEW=$(curl --silent --show-error -L --max-redirs 0 --fail \
		-X GET \
		-H "Authorization: Key ${API_KEY_NEW}" \
		"${RSC_NEW}/__api__/v1/users" | jq --arg NAME_OWNER_OLD "$NAME_OWNER_OLD" -r '.results[] | select(.username==$NAME_OWNER_OLD) | .guid')

	# get GUID of new admin
	ADMIN_GUID_NEW=$(curl --silent --show-error -L --max-redirs 0 --fail \
		-X GET \
		-H "Authorization: Key ${API_KEY_NEW}" \
		"${RSC_NEW}/__api__/v1/users" | jq --arg ADMIN_NEW "$ADMIN_NEW" -r '.results[] | select(.username==$ADMIN_NEW) | .guid')

	DATA="{
  \"owner_guid\": \"${OWNER_GUID_NEW}\"
}"

	curl --silent --show-error -L --max-redirs 0 --fail \
		-X PATCH \
		-H "Authorization: Key ${API_KEY_NEW}" \
		--data-raw "${DATA}" \
		"${RSC_NEW}/__api__/v1/content/${GUID_NEW}" >/dev/null
fi

# restore access type ---------------------------------------------------------#

echo -e "STEP: Restoring 'access_type'"

ACCESS_TYPE_OLD=$(curl --silent --show-error -L --max-redirs 0 --fail \
	-X GET \
	-H "Authorization: Key ${API_KEY_OLD}" \
	"${RSC_OLD}/__api__/v1/content/${GUID_OLD}" | jq -r '.access_type')

DATA="{
  \"access_type\": \"${ACCESS_TYPE_OLD}\"
}"

curl --silent --show-error -L --max-redirs 0 --fail \
	-X PATCH \
	-H "Authorization: Key ${API_KEY_NEW}" \
	--data-raw "${DATA}" \
	"${RSC_NEW}/__api__/v1/content/${GUID_NEW}" >/dev/null >/dev/null

# restore title ---------------------------------------------------------------#

echo -e "STEP: Restoring 'title'"

TITLE_OLD=$(curl --silent --show-error -L --max-redirs 0 --fail \
	-X GET \
	-H "Authorization: Key ${API_KEY_OLD}" \
	"${RSC_OLD}/__api__/v1/content/${GUID_OLD}" | jq -r '.title')

DATA="{
  \"title\": \"${TITLE_OLD}\"
}"

curl --silent --show-error -L --max-redirs 0 --fail \
	-X PATCH \
	-H "Authorization: Key ${API_KEY_NEW}" \
	--data-raw "${DATA}" \
	"${RSC_NEW}/__api__/v1/content/${GUID_NEW}" >/dev/null >/dev/null

# restore 'max_processes' -----------------------------------------------------#

echo -e "STEP: Restoring 'max_processes'"

MAX_PROCESSES_OLD=$(curl --silent --show-error -L --max-redirs 0 --fail \
	-X GET \
	-H "Authorization: Key ${API_KEY_OLD}" \
	"${RSC_OLD}/__api__/v1/content/${GUID_OLD}" | jq -r '.max_processes')

DATA="{
  \"max_processes\": \"${MAX_PROCESSES_OLD}\"
}"

if [[ $MAX_PROCESSES_OLD != "null" ]]; then

	curl --silent --show-error -L --max-redirs 0 --fail \
		-X PATCH \
		-H "Authorization: Key ${API_KEY_NEW}" \
		--data-raw "${DATA}" \
		"${RSC_NEW}/__api__/v1/content/${GUID_NEW}" >/dev/null >/dev/null
fi

# restore 'min_processes' -----------------------------------------------------#

echo -e "STEP: Restoring 'min_processes'"

MIN_PROCESSES_OLD=$(curl --silent --show-error -L --max-redirs 0 --fail \
	-X GET \
	-H "Authorization: Key ${API_KEY_OLD}" \
	"${RSC_OLD}/__api__/v1/content/${GUID_OLD}" | jq -r '.min_processes')

DATA="{
  \"min_processes\": \"${MIN_PROCESSES_OLD}\"
}"

if [[ $MIN_PROCESSES_OLD != "null" ]]; then

	curl --silent --show-error -L --max-redirs 0 --fail \
		-X PATCH \
		-H "Authorization: Key ${API_KEY_NEW}" \
		--data-raw "${DATA}" \
		"${RSC_NEW}/__api__/v1/content/${GUID_NEW}" >/dev/null
fi

# restore 'max_conns_per_process' ---------------------------------------------#

echo -e "STEP: Restoring 'max_conns_per_process'"

MAX_CONNS_PER_PROCESS_OLD=$(curl --silent --show-error -L --max-redirs 0 --fail \
	-X GET \
	-H "Authorization: Key ${API_KEY_OLD}" \
	"${RSC_OLD}/__api__/v1/content/${GUID_OLD}" | jq -r '.max_conns_per_process')

DATA="{
  \"max_conns_per_process\": \"${MAX_CONNS_PER_PROCESS_OLD}\"
}"

if [[ $MAX_CONNS_PER_PROCESS_OLD != "null" ]]; then

	curl --silent --show-error -L --max-redirs 0 --fail \
		-X PATCH \
		-H "Authorization: Key ${API_KEY_NEW}" \
		--data-raw "${DATA}" \
		"${RSC_NEW}/__api__/v1/content/${GUID_NEW}" >/dev/null
fi

# restore 'description' --------------------------------------------------------#

echo -e "STEP: Restoring 'description'"

DESCRIPTION_OLD=$(curl --silent --show-error -L --max-redirs 0 --fail \
	-X GET \
	-H "Authorization: Key ${API_KEY_OLD}" \
	"${RSC_OLD}/__api__/v1/content/${GUID_OLD}" | jq -r '.description')

DATA="{
  \"description\": \"${DESCRIPTION_OLD}\"
}"

if [[ $DESCRIPTION_OLD != "null" ]]; then
	curl --silent --show-error -L --max-redirs 0 --fail \
		-X PATCH \
		-H "Authorization: Key ${API_KEY_NEW}" \
		--data-raw "${DATA}" \
		"${RSC_NEW}/__api__/v1/content/${GUID_NEW}" >/dev/null
fi

# restore vanity URL ----------------------------------------------------------#

echo -e "STEP: Restoring 'vanity URL'"

VANITY_PATH=$(curl --silent --show-error -L --max-redirs 0 --fail \
	-X GET \
	-H "Authorization: Key ${API_KEY_OLD}" \
	"${RSC_OLD}/__api__/v1/content/${GUID_OLD}/vanity" | jq -r '.path')

DATA="{
  \"force\": false,
  \"path\": \"${VANITY_PATH}\"
}"

if [[ $VANITY_PATH != "null" ]]; then

	curl --silent --show-error -L --max-redirs 0 --fail \
		-X PUT \
		-H "Authorization: Key ${API_KEY_NEW}" \
		--data-raw "${DATA}" \
		"${RSC_NEW}/__api__/v1/content/${GUID_NEW}/vanity" >/dev/null
fi

# restore tags for apps -------------------------------------------------------#

echo -e "STEP: Restoring tags for content"

TAGS_OLD=$(curl --silent --show-error -L --max-redirs 0 --fail \
	-X GET \
	-H "Authorization: Key ${API_KEY_OLD}" \
	"${RSC_OLD}/__api__/v1/content/${GUID_OLD}/tags" | jq -r '.[] | .name')

for TAG_NAME in $TAGS_OLD; do

	TAG_ID_NEW=$(curl --silent --show-error -L --max-redirs 0 --fail \
		-X GET \
		-H "Authorization: Key ${API_KEY_NEW}" \
		"${RSC_NEW}/__api__/v1/tags" | jq -r --arg TAG_NAME "$TAG_NAME" '.[] | select(.name==$TAG_NAME) | .id')

	DATA="{
  \"tag_id\": \"${TAG_ID_NEW}\"
}"

	curl --silent --show-error -L --max-redirs 0 --fail \
		-X POST \
		-H "Authorization: Key ${API_KEY_NEW}" \
		--data-raw "${DATA}" \
		"${RSC_NEW}/__api__/v1/content/${GUID_NEW}/tags" >/dev/null
done

cd ..
rm -rf migrate-${APP_NAME}
