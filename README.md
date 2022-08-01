# Migrate content between RStudio/Posit Connect instances

## Usage

1. Define the env vars listed under "Prerequisites" and "Env vars"
1. Run the script `connect-migrate.sh <app name>`

With all the env vars described below, a full workflow could look like this:

```sh
export API_KEY_OLD=
export API_KEY_NEW=
export CONNECT_OLD=
export CONNECT_NEW=
export ADMIN_OLD=
export ADMIN_NEW=
export USER_NEW=
export SERVER_NAME_NEW=

export REBUILD_CONTENT=false
export RESTORE_TAG_SCHEMA=false

connect-migrate.sh <app name>
```

Optionally, the script can also be run in parallel to process all old apps at once via

```bash
export API_KEY_OLD=
export API_KEY_NEW=
export CONNECT_OLD=
export CONNECT_NEW=
export ADMIN_OLD=
export ADMIN_NEW=
export USER_NEW=
export SERVER_NAME_NEW=

export REBUILD_CONTENT=true
export RESTORE_TAG_SCHEMA=true

APPS_TO_MIGRATE=$(curl --silent --show-error -L --max-redirs 0 --fail \
	-X GET \
	-H "Authorization: Key ${API_KEY_OLD}" \
	"${CONNECT_OLD}/__api__/v1/content?page_size=500" | jq -r '.[].name' | sort -u)

# source: https://unix.stackexchange.com/a/216475/135691
IFS=$'\n'
N=1 # number of parallel processes
for APP_NAME in $APPS_TO_MIGRATE ; do
   ((i=i%N)); ((i++==0)) && wait
   connect-migrate.sh "$APP_NAME" &
done
unset IFS
```

## Prerequisites

| Name              | Description                                                                                                                                             |
| :---------------- | :------------------------------------------------------------------------------------------------------------------------------------------------------ |
| `API_KEY_OLD`     | API key of old Connect instance                                                                                                                         |
| `API_KEY_NEW`     | API key of new Connect instance                                                                                                                         |
| `CONNECT_OLD`     | URL of old Connect instance (format: `https://<some>.<domain>`)                                                                                         |
| `CONNECT_NEW`     | URL of new Connect instance (format: `https://<some>.<domain>`)                                                                                         |
| `ADMIN_OLD`       | Name of account with admin privileges on old Connect instance                                                                                           |
| `ADMIN_NEW`       | Name of account with admin privileges on old Connect instance                                                                                           |
| `USER_NEW`        | Username passed to `rsconnect::connectApiUser(account = ` for CLI authentication                                                                    |
| `SERVER_NAME_NEW` | Server name passed to `rsconnect::addConnectServer(server = )`, `rsconnect::connectApiUser(server = ` and `rsconnect::deployApp(server = )` |

## Options: set via env vars

- RESTORE_TAGS: [true|false]: whether to restore tags from the old Connect instance
- REBUILD_CONTENT: [true|false]: whether to rebuild and deploy content from the old Connect instance

## Execution tips

- After the first rebuild and publishing of apps, set `REBUILD_CONTENT=false` to avoid another rebuild and only force metadata updates
- The tag schema only needs to be restored once, so after the first run `RESTORE_TAG_SCHEMA=false` can be set

## Non-migratable parts / known issues

- Restoring of environment variables in apps: these might contain sensitive information and can hence not be retrieved via the API.
- During the initial release of this script, `quarto` deployments were not successfully restored (`quarto` version 1.1.19)
- An app cannot be restored if the repos in the manifest cannot be found (anymore).
  One case in which this happens is when a fixed RSPM snapshot was used (such as `[...]/all/__linux__/focal/2022-02-07+Y3Jhbiw2ODo2NTkwNjE2O0UwREE3Njkw`) which is not available in the new instance
- The script creates dummy accounts for the old owners in the new instance.
  This functionality has so far only been tested with OAuth2 and might fail if your instance runs with SAML or AD authentication.
  In this case small changes to the `/users` endpoint call might be necessary - PRs welcome!
