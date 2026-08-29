-- Create MLflow tracking database and user.
-- These scripts run only on the FIRST start of an empty volume.

CREATE USER mlflow WITH PASSWORD 'mlflow';
CREATE DATABASE mlflow OWNER mlflow;
GRANT ALL PRIVILEGES ON DATABASE mlflow TO mlflow;
