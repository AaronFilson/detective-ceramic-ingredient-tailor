import { App, RemovalPolicies } from 'aws-cdk-lib';
import { DciTailorStack, readDciTailorSettings } from '../lib/dci-tailor-stack.ts';

export function buildDciTailorApp(context?: Record<string, unknown>): {
  readonly app: App;
  readonly stack: DciTailorStack;
} {
  const app = new App({ analyticsReporting: false, context });
  const settings = readDciTailorSettings(app.node);

  const stack = new DciTailorStack(app, 'dci-tailor-infra', {
    env: { account: settings.account, region: settings.region },
    description:
      'DCI Tailor: private encrypted S3 storage + pgdump bucket, least-privilege IAM storage user, SSM bucket parameter, and GitHub Actions OIDC deploy role',
    terminationProtection: true,
    settings
  });

  RemovalPolicies.of(app).retainOnUpdateOrDelete();

  return { app, stack };
}

if (import.meta.url === `file://${process.argv[1]}`) {
  buildDciTailorApp();
}
