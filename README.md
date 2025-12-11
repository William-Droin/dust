## How to start the project

### Fast dev start

make sure that you have all of the correct env variables set (they can be found in the init_dev_container.sh, front .env and core.env files) TO RASSEMBLE AT SOME POINT

```
docker-compose up

./init_dev_container.sh
# follow instructions at the end of the previous command to fully star everything

mprocs --config tools/mprocs.yaml
```

After logging in a root user, you will need to run
```
npx tsx admin/init_dust_apps.ts --sId=<root-user-workspace-id>
```

and then restart the whole app with the correct DUST_APPS_WORKSPACE_ID and DUST_APPS_SPACE_ID

### Rust backend

First export 
```
export CORE_DATABASE_URI=postgresql://dev:dev@localhost:5432/dust_api && export DISABLE_API_KEY_CHECK=true && export DUST_API_KEY=mytestkey && export ELASTICSEARCH_PASSWORD=changeme && export ELASTICSEARCH_URL=http://localhost:9200 && export ELASTICSEARCH_USERNAME=elastic && export QDRANT_CLUSTER_0_API_KEY='' && export QDRANT_CLUSTER_0_KEY=key && export QDRANT_CLUSTER_0_URL=http://localhost:6333 && export QDRANT_URL=http://localhost:6333 && export REDIS_URI=redis://localhost:6379 && export REDIS_URL=redis://localhost:6379
```

### Node front end

- First build the DB:
```
npx tsx admin/db.ts
```

- Change the plan code according parameters according to what ever you wan the users to have and then initialise the plans
```
npx tsx admin/init_plans.ts
```
Careful that the plan as "canUseProduct" set to true

- Create a WorkOS account and set up the credentials as part of the .env file

add the 

- Start a Temporal server

```
temporal server start-dev
```
or 

add it to the docker compose file to be started with the rest of the infra

this needs to be done afterwards
```
# In another terminal, register search attributes
temporal operator search-attribute create \
  --namespace default \
  --name conversationId \
  --type Text

temporal operator search-attribute create \
  --namespace default \
  --name workspaceId \
  --type Text
```

- Add workspaces ID in DB

```
npx tsx admin/init_dust_apps.ts --sID XXXX --name XXXXX
```

- Start all the services (sqlite_worker, oauth)
```
./tools/start-mprocs.sh
```
or
```
export DISABLE_API_KEY_CHECK=true
cargo run --bin oauth
```

## Default agent

if you want to disable default agents use the API, could be ran as part of the docker set up:

```
// Example to disable the Noop agent:
fetch(`/api/w/${workspaceId}/assistant/global_agents/noop`, {
  method: 'PATCH',
  headers: { 'Content-Type': 'application/json' },
  body: JSON.stringify({ status: "disabled_by_admin" })
});
```