## This is the init script used to initialize the development environment.

## Initializing PostgresSQL databases

export FRONT_DATABASE_URI=postgresql://dev:dev@localhost:5432/dust_front;
export QDRANT_CLUSTER_0_URL=http://localhost:6334;
export QDRANT_CLUSTER_0_API_KEY=null;
export ELASTICSEARCH_PASSWORD="changeme";
export ELASTICSEARCH_URL="http://elastic:${ELASTICSEARCH_PASSWORD}@localhost:9200";
export ELASTICSEARCH_USERNAME="elastic";
export DUST_REGION=europe-west1;
export CONNECTORS_DATABASE_URI=postgres://dev:dev@localhost:5432/dust_connectors;
export CORE_DATABASE_URI=postgresql://dev:dev@localhost:5432/dust_api;
export OAUTH_DATABASE_URI=postgresql://dev:dev@localhost:5432/dust_oauth;


if [[ "$1" == "--reset-db" ]]; then
    psql "postgres://dev:dev@localhost:5432/" -c "DROP DATABASE dust_api;"
    psql "postgres://dev:dev@localhost:5432/" -c "DROP DATABASE dust_databases_store;"
    psql "postgres://dev:dev@localhost:5432/" -c "DROP DATABASE dust_front;"
    psql "postgres://dev:dev@localhost:5432/" -c "DROP DATABASE dust_front_test;"
    psql "postgres://dev:dev@localhost:5432/" -c "DROP DATABASE dust_connectors;"
    psql "postgres://dev:dev@localhost:5432/" -c "DROP DATABASE dust_connectors_test;"
    psql "postgres://dev:dev@localhost:5432/" -c "DROP DATABASE dust_oauth;"
else
    echo "Skipping database reset. Use --reset-db to drop existing databases."
fi


psql "postgres://dev:dev@localhost:5432/" -c "CREATE DATABASE dust_api;";
psql "postgres://dev:dev@localhost:5432/" -c "CREATE DATABASE dust_databases_store;";
psql "postgres://dev:dev@localhost:5432/" -c "CREATE DATABASE dust_front;";
psql "postgres://dev:dev@localhost:5432/" -c "CREATE DATABASE dust_front_test;";
psql "postgres://dev:dev@localhost:5432/" -c "CREATE DATABASE dust_connectors;";
psql "postgres://dev:dev@localhost:5432/" -c "CREATE DATABASE dust_connectors_test;";
psql "postgres://dev:dev@localhost:5432/" -c "CREATE DATABASE dust_oauth;";

## Initilizing Qdrant collections
cd core/
cargo run --bin qdrant_create_collection -- --cluster cluster-0 --provider openai --model text-embedding-3-large-1536
cd -

## Initializing Elasticsearch indices
cd core/
cargo run --bin elasticsearch_create_index -- --index-name data_sources_nodes --index-version 4 --skip-confirmation
cargo run --bin elasticsearch_create_index -- --index-name data_sources --index-version 1 --skip-confirmation
cd -

echo "--"
echo "You should now run the following commands to setup the tables within the databases:"
echo "cd front && ./admin/init_db.sh --unsafe && cd -"
echo "cd front && ./admin/init_plans.sh --unsafe && cd -"
echo "cd connectors && ./admin/init_db.sh --unsafe && cd -"
echo "cd core && cargo run --bin init_db && cd -"