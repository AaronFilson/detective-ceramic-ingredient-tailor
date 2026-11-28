import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { describe, it } from 'node:test';
import { Match, Template } from 'aws-cdk-lib/assertions';
import { buildDciTailorApp } from '../bin/app.ts';

const CDK_JSON_CONTEXT = (
  JSON.parse(readFileSync(new URL('../cdk.json', import.meta.url), 'utf8')) as { context: Record<string, unknown> }
).context;

function synthTemplate(overrides: Record<string, unknown> = {}): Template {
  const { stack } = buildDciTailorApp({
    ...CDK_JSON_CONTEXT,
    ...overrides
  });
  return Template.fromStack(stack);
}

describe('DciTailorStack', () => {
  it('creates a private AES256-encrypted S3 bucket with TLS enforcement, CORS, and lifecycle rules', () => {
    const template = synthTemplate();

    template.hasResourceProperties('AWS::S3::Bucket', {
      BucketName: 'dci-tailor-storage-724654236968',
      PublicAccessBlockConfiguration: {
        BlockPublicAcls: true,
        BlockPublicPolicy: true,
        IgnorePublicAcls: true,
        RestrictPublicBuckets: true
      },
      BucketEncryption: {
        ServerSideEncryptionConfiguration: [
          {
            ServerSideEncryptionByDefault: {
              SSEAlgorithm: 'AES256'
            }
          }
        ]
      },
      CorsConfiguration: {
        CorsRules: [
          {
            AllowedHeaders: ['*'],
            AllowedMethods: ['GET', 'HEAD', 'PUT', 'POST'],
            AllowedOrigins: [
              'https://dci-tailor.glazecalcapp.com',
              'https://dci-tailor-staging.glazecalcapp.com'
            ],
            ExposedHeaders: ['ETag'],
            MaxAge: 3600
          }
        ]
      },
      LifecycleConfiguration: {
        Rules: Match.arrayWith([
          Match.objectLike({
            Id: 'expire-staging-uploads',
            Prefix: 'staging/',
            ExpirationInDays: 14,
            Status: 'Enabled'
          }),
          Match.objectLike({
            Id: 'expire-pgdumps',
            Prefix: 'pgdump/',
            ExpirationInDays: 30,
            Status: 'Enabled'
          })
        ])
      }
    });

    template.hasResourceProperties('AWS::S3::BucketPolicy', {
      PolicyDocument: {
        Statement: Match.arrayWith([
          Match.objectLike({
            Effect: 'Deny',
            Action: 's3:*',
            Condition: {
              Bool: {
                'aws:SecureTransport': 'false'
              }
            }
          })
        ])
      }
    });
  });

  it('creates least-privilege IAM user dci-tailor-storage scoped strictly to the storage bucket', () => {
    const template = synthTemplate();

    template.hasResourceProperties('AWS::IAM::User', {
      UserName: 'dci-tailor-storage'
    });

    template.hasResourceProperties('AWS::IAM::Policy', {
      PolicyName: 'dci-tailor-s3-storage',
      PolicyDocument: {
        Statement: [
          {
            Sid: 'ReadWriteDeleteStorageObjects',
            Effect: 'Allow',
            Action: ['s3:GetObject', 's3:PutObject', 's3:DeleteObject'],
            Resource: Match.anyValue()
          },
          {
            Sid: 'ListStorageBucket',
            Effect: 'Allow',
            Action: 's3:ListBucket',
            Resource: Match.anyValue()
          }
        ]
      }
    });
  });

  it('publishes the storage bucket name in SSM parameter /dci-tailor/storage-bucket', () => {
    const template = synthTemplate();

    template.hasResourceProperties('AWS::SSM::Parameter', {
      Name: '/dci-tailor/storage-bucket',
      Type: 'String'
    });
  });

  it('creates GitHub Actions OIDC role dci-tailor-deploy scoped strictly to the repo and app=glazecalc instance', () => {
    const template = synthTemplate();

    template.hasResourceProperties('AWS::IAM::Role', {
      RoleName: 'dci-tailor-deploy',
      AssumeRolePolicyDocument: {
        Statement: [
          {
            Effect: 'Allow',
            Action: 'sts:AssumeRoleWithWebIdentity',
            Principal: {
              Federated: 'arn:aws:iam::724654236968:oidc-provider/token.actions.githubusercontent.com'
            },
            Condition: {
              StringEquals: {
                'token.actions.githubusercontent.com:aud': 'sts.amazonaws.com'
              },
              StringLike: {
                'token.actions.githubusercontent.com:sub': 'repo:AaronFilson/detective-ceramic-ingredient-tailor:*'
              }
            }
          }
        ]
      },
      Policies: [
        {
          PolicyName: 'dci-tailor-ssm-deploy',
          PolicyDocument: {
            Statement: Match.arrayWith([
              Match.objectLike({
                Sid: 'SessionAndRunCommandOnHostInstance',
                Effect: 'Allow',
                Action: ['ssm:StartSession', 'ssm:SendCommand'],
                Resource: 'arn:aws:ec2:us-west-2:724654236968:instance/*',
                Condition: {
                  StringEquals: {
                    'ssm:resourceTag/app': 'glazecalc'
                  }
                }
              }),
              Match.objectLike({
                Sid: 'ReadDciTailorSsmSecrets',
                Effect: 'Allow',
                Action: ['ssm:GetParameter', 'ssm:GetParameters', 'ssm:GetParametersByPath'],
                Resource: [
                  'arn:aws:ssm:us-west-2:724654236968:parameter/dci-tailor',
                  'arn:aws:ssm:us-west-2:724654236968:parameter/dci-tailor/*'
                ]
              })
            ])
          }
        }
      ]
    });
  });

  it('rejects malformed AWS account context settings at synth time', () => {
    assert.throws(() => synthTemplate({ account: 'not-an-account' }), /Context account must match/);
  });
});
