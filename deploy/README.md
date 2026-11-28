# Deploying DCI Tailor (`dci-tailor.glazecalcapp.com`)

DCI Tailor runs alongside `glazecalc` on the single Graviton `t4g.small` (2 GB RAM + 2 GB swap) EC2 instance in `us-west-2` (`glazecalcapp.com`, AWS account `724654236968`), managed by **Kamal 2** over **AWS Systems Manager (SSM) Session Manager** with **zero open SSH ports**.

## Host Port & Memory Map (`t4g.small` — 2,048 MB RAM)

| Service | Host Loopback Port | Container Memory Cap | Notes |
| --- | --- | --- | --- |
| Host Nginx | `:80`, `:443` (public) | ~30 MB | Terminates Let's Encrypt TLS for all `*.glazecalcapp.com` virtual hosts |
| `glazecalc` (prod) | `127.0.0.1:3000` | `512m` (~180 MB RSS) | Existing Node/Mongo production app |
| `glazecalc-staging` | `127.0.0.1:3001` | `300m` (~120 MB RSS) | Existing Node staging app (`oom_score_adj: 500`) |
| `kamal-proxy` (DCI Tailor) | `127.0.0.1:3002` (HTTP), `127.0.0.1:3443` (HTTPS) | ~30 MB | Routes both `dci-tailor.glazecalcapp.com` and `dci-tailor-staging.glazecalcapp.com` by `Host` header |
| `dci-tailor-web` (prod) | internal `:80` (Thruster) | `512m` (~230 MB RSS) | Ruby 3.3 + `jemalloc` + Puma single-process (`WEB_CONCURRENCY=0`) + SolidQueue in Puma |
| `dci-tailor-staging-web` | internal `:80` (Thruster) | `320m` (~185 MB RSS) | `oom-score-adj: 500`, `cpus: 0.5`, `RUBY_YJIT_ENABLE=0`, `RAILS_MAX_THREADS=2`, `JOB_THREADS=1` |
| `dci-tailor-db` (PostGIS 16) | `127.0.0.1:5433` | `320m` (~140 MB RSS) | Shared by `dci_tailor_production` and isolated `dci_tailor_staging` (`shared_buffers=96MB`, `max_connections=25`) |

---

## Step 1: Resize `t4g.micro` -> `t4g.small` & Expand EBS to 30 GB (~60s Maintenance)

Find the running `glazecalc` instance and root volume:

```bash
INSTANCE_ID=$(aws ec2 describe-instances --region us-west-2 \
  --filters "Name=tag:app,Values=glazecalc" "Name=instance-state-name,Values=running" \
  --query "Reservations[0].Instances[0].InstanceId" --output text)

VOLUME_ID=$(aws ec2 describe-instances --region us-west-2 \
  --instance-ids "$INSTANCE_ID" \
  --query "Reservations[0].Instances[0].BlockDeviceMappings[0].Ebs.VolumeId" --output text)
```

1. **Expand GP3 EBS volume online from 20 GB to 30 GB (zero downtime):**
   ```bash
   aws ec2 modify-volume --region us-west-2 --volume-id "$VOLUME_ID" --size 30
   ```
   Then inside an SSM session (`aws ssm start-session --region us-west-2 --target "$INSTANCE_ID"`):
   ```bash
   sudo growpart /dev/nvme0n1 1
   sudo resize2fs /dev/nvme0n1p1
   df -h /
   ```
2. **Upgrade instance type from `t4g.micro` (1 GB) to `t4g.small` (2 GB):**
   ```bash
   aws ec2 stop-instances --region us-west-2 --instance-ids "$INSTANCE_ID"
   aws ec2 wait instance-stopped --region us-west-2 --instance-ids "$INSTANCE_ID"
   aws ec2 modify-instance-attribute --region us-west-2 --instance-id "$INSTANCE_ID" \
     --instance-type "{\"Value\": \"t4g.small\"}"
   aws ec2 start-instances --region us-west-2 --instance-ids "$INSTANCE_ID"
   aws ec2 wait instance-running --region us-west-2 --instance-ids "$INSTANCE_ID"
   ```
   *(Elastic IP remains attached automatically on stop/start; also update `instanceType` in `glazecalc/deploy/cdk` when convenient.)*

---

## Step 2: Deploy the AWS CDK Stack (`deploy/cdk`)

Synthesize, test, and deploy `dci-tailor-infra` (creates private encrypted S3 bucket `dci-tailor-storage-724654236968`, scoped IAM user `dci-tailor-storage`, `/dci-tailor/storage-bucket` SSM parameter, and `dci-tailor-deploy` GitHub OIDC role):

```bash
cd deploy/cdk
npm install
npm test
npx cdk diff
npx cdk deploy
```

Also grant the EC2 instance role (`glazecalc-instance`) permission to read `/dci-tailor/storage-bucket` and upload `s3://dci-tailor-storage-724654236968/pgdump/*` (or configure `/root/.aws/credentials` for `backup-postgres.sh`), and create an access key for IAM user `dci-tailor-storage` to store in SSM below.

---

## Step 3: Populate SSM Parameter Store Secrets

Store production and staging secrets as `SecureString` parameters in `us-west-2`:

```bash
# Production (/dci-tailor/prod/*)
aws ssm put-parameter --region us-west-2 --type SecureString --overwrite \
  --name /dci-tailor/prod/secret-key-base --value "$(bin/rails secret)"
aws ssm put-parameter --region us-west-2 --type SecureString --overwrite \
  --name /dci-tailor/prod/postgres-password --value "$(openssl rand -hex 24)"
aws ssm put-parameter --region us-west-2 --type SecureString --overwrite \
  --name /dci-tailor/prod/aws-access-key-id --value "<DCI_TAILOR_STORAGE_ACCESS_KEY_ID>"
aws ssm put-parameter --region us-west-2 --type SecureString --overwrite \
  --name /dci-tailor/prod/aws-secret-access-key --value "<DCI_TAILOR_STORAGE_SECRET_ACCESS_KEY>"
aws ssm put-parameter --region us-west-2 --type SecureString --overwrite \
  --name /dci-tailor/prod/smtp-url --value "smtp://<SES_USER>:<SES_PASS>@email-smtp.us-west-2.amazonaws.com:587"

# Staging (/dci-tailor/staging/*)
aws ssm put-parameter --region us-west-2 --type SecureString --overwrite \
  --name /dci-tailor/staging/secret-key-base --value "$(bin/rails secret)"
aws ssm put-parameter --region us-west-2 --type SecureString --overwrite \
  --name /dci-tailor/staging/postgres-password --value "$(openssl rand -hex 24)"
aws ssm put-parameter --region us-west-2 --type SecureString --overwrite \
  --name /dci-tailor/staging/aws-access-key-id --value "<DCI_TAILOR_STORAGE_ACCESS_KEY_ID>"
aws ssm put-parameter --region us-west-2 --type SecureString --overwrite \
  --name /dci-tailor/staging/aws-secret-access-key --value "<DCI_TAILOR_STORAGE_SECRET_ACCESS_KEY>"
```

*(Optional geological API keys: `/dci-tailor/prod/mindat-api-token` and `/dci-tailor/prod/georoc-api-key`.)*

---

## Step 4: DNS, Certbot TLS & Host Nginx Virtual Hosts

1. Point Route 53 `A` / `AAAA` records for `dci-tailor.glazecalcapp.com` and `dci-tailor-staging.glazecalcapp.com` at the `glazecalc` Elastic IP.
2. Issue Let's Encrypt certificates on the EC2 host using the existing `/var/www/certbot` webroot:
   ```bash
   sudo certbot certonly --webroot -w /var/www/certbot -d dci-tailor.glazecalcapp.com
   sudo certbot certonly --webroot -w /var/www/certbot -d dci-tailor-staging.glazecalcapp.com
   ```
3. Install `deploy/nginx/dci-tailor.conf` and `deploy/nginx/dci-tailor-staging.conf`:
   ```bash
   sudo cp deploy/nginx/dci-tailor.conf /etc/nginx/sites-available/dci-tailor
   sudo cp deploy/nginx/dci-tailor-staging.conf /etc/nginx/sites-available/dci-tailor-staging
   sudo ln -sfn /etc/nginx/sites-available/dci-tailor /etc/nginx/sites-enabled/dci-tailor
   sudo ln -sfn /etc/nginx/sites-available/dci-tailor-staging /etc/nginx/sites-enabled/dci-tailor-staging
   sudo nginx -t && sudo systemctl reload nginx
   ```

---

## Step 5: Configure SSH-over-SSM & Run Kamal Setup / Deploy

1. Copy [`deploy/ssh-ssm-config.example`](./ssh-ssm-config.example) into `~/.ssh/config` with your live `InstanceId` (`Host glazecalc-ec2`), and ensure your SSH public key is in `/home/admin/.ssh/authorized_keys` (and `admin` is in the `docker` group: `sudo usermod -aG docker admin`).
2. Validate Kamal configs locally:
   ```bash
   bundle exec kamal config
   bundle exec kamal config -d staging
   ```
3. Bootstrap `dci-tailor-db`, `kamal-proxy` (`127.0.0.1:3002`), and production `dci-tailor`:
   ```bash
   AWS_REGION=us-west-2 KAMAL_REGISTRY_PASSWORD="$GITHUB_TOKEN" bundle exec kamal setup
   ```
4. Set the `dci_tailor_staging` database role password inside `dci-tailor-db` (once):
   ```bash
   STAGING_DB_PASS=$(aws ssm get-parameter --region us-west-2 --with-decryption \
     --name /dci-tailor/staging/postgres-password --query Parameter.Value --output text)
   ssh glazecalc-ec2 "docker exec dci-tailor-db psql -U dci_tailor -d dci_tailor_production \
     -c \"ALTER ROLE dci_tailor_staging WITH PASSWORD '${STAGING_DB_PASS}';\""
   ```
5. Deploy staging (~200 MB RAM alongside production, sharing `kamal-proxy` and `dci-tailor-db`):
   ```bash
   AWS_REGION=us-west-2 KAMAL_REGISTRY_PASSWORD="$GITHUB_TOKEN" bundle exec kamal deploy -d staging
   ```
   To stop staging between testing rounds and reclaim ~185 MB RAM:
   ```bash
   AWS_REGION=us-west-2 bundle exec kamal app stop -d staging
   ```

---

## Step 6: Nightly PostGIS Backups & Restore

1. Copy `deploy/backup-postgres.sh` to `/usr/local/bin/dci-tailor-backup-postgres.sh` (`chmod 755`) and schedule via `/etc/cron.d/dci-tailor-backup` (e.g., `25 4 * * * root /usr/local/bin/dci-tailor-backup-postgres.sh >> /var/log/dci-tailor-backup.log 2>&1`).
2. **Test a backup manually:**
   ```bash
   sudo /usr/local/bin/dci-tailor-backup-postgres.sh
   ```
3. **Restore a custom-format dump (`pg_restore`):**
   ```bash
   aws s3 cp s3://dci-tailor-storage-724654236968/pgdump/<dump-file>.dump /tmp/restore.dump
   docker exec -i dci-tailor-db sh -c \
     'PGPASSWORD="$POSTGRES_PASSWORD" pg_restore --clean --if-exists --no-owner --no-acl -U "$POSTGRES_USER" -d dci_tailor_production' \
     < /tmp/restore.dump
   rm -f /tmp/restore.dump
   ```
