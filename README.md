# Photogrammetry

A small image-collection and metadata service. Users upload a photo together
with where, when, and how it was taken; the image bytes go to S3 while the
metadata is stored in RDB and later exposed through a read-only Lambda API.

## What's In The Repository

| Path | Purpose |
| --- | --- |
| `deploy.sh` | Builds the artifacts, deploys the stack, and publishes the frontend |
| `frontend/` | Static pages: upload form (`index.html`, `app.js`) and image search (`search.html`, `search.js`), sharing `styles.css` |
| `lambda/` | Capture service: validates metadata, writes a DB row, returns a pre-signed S3 PUT URL |
| `query/` | Read-only Flask API over the `images` table (`GET /images`, `GET /image`) |
| `templates/` | CloudFormation stacks: the network (VPC), the storage layer draft, and the running services |

## Architecture

```mermaid
flowchart LR
    subgraph Edge["Edge"]
        Browser["Browser<br/>SPA upload + search"]
        CF["CloudFront distribution<br/>single domain, path routing"]
        FrontendBucket["S3 frontend bucket<br/>static site, private via OAC"]
    end

    subgraph Capture["Capture tier"]
        LambdaURL["Lambda Function URL<br/>AuthType NONE, CORS POST/OPTIONS"]
        CaptureLambda["Capture Lambda<br/>python3.12"]
    end

    subgraph Query["Query tier"]
        ALB["ALB, internet-facing<br/>:80 HTTP"]
        QueryEC2["EC2 t3.micro<br/>gunicorn + Flask :8080"]
    end

    subgraph Data["Data layer (external, persistence stack)"]
        ImageBucket["S3 image-bucket"]
        RDS["RDS MySQL :3306<br/>images table"]
    end

    Browser -->|"POST /api/images<br/>(metadata JSON)"| CF
    CF -->|"/api/*"| LambdaURL
    LambdaURL --> CaptureLambda
    CaptureLambda -->|"INSERT row"| RDS
    CaptureLambda -->|"201 + pre-signed PUT URL"| Browser
    Browser -->|"PUT image bytes<br/>(pre-signed, direct to S3)"| ImageBucket

    CF -->|"/images, /image"| ALB
    ALB -->|"forward :8080 (ALB SG)"| QueryEC2
    ALB -.->|"health check GET /health"| QueryEC2
    QueryEC2 -->|"SELECT"| RDS
    QueryEC2 -->|"302 redirect<br/>pre-signed GET"| ImageBucket

    CF -->|"/* everything else"| FrontendBucket
```

CloudFront fronts a single domain and routes by path: `/api/*` to the capture
Lambda, `/images` and `/image` to the query service behind an Application Load
Balancer, and all other paths to the static frontend bucket.

## Components

### Frontend (`frontend/`)

Two static pages sharing one stylesheet.

`index.html` is the upload form: pick an image (with local preview), fill in a
name, location, coordinates, altitude, capture time, description, and
heading/pitch/roll. On submit it POSTs the metadata as JSON to `/api/images`,
then PUTs the raw file to the pre-signed URL the API returns. The response is
echoed into a `<pre>` block and to `console.log`.

`search.html` is the image search page. Every filterable field offers a mode
toggle: text fields (`name`, `location`, `description`) take
`Any`/`Fuzzy`/`Exact`, and numeric and datetime fields take
`Any`/`Exact`/`Range`. In `Fuzzy` mode it sends `<field>Fuzzy` and the results
come back relevance-ranked (each card shows a Match percentage); `Exact` sends
`<field>Exact`; `Range` sends `<field>Min`/`<field>Max` (numeric) or
`<field>Since`/`<field>Before` (datetime). Results render as a grid of
thumbnails (each loaded through `/image?url=`) with metadata captions, plus
ordering, a fuzzy threshold, a page size, and prev/next paging. All values are
written with DOM text APIs, never raw HTML.

### Capture Lambda (`lambda/`)

`lambda_function.py` runs on Python 3.12. It:

1. Parses and validates the request body, requiring `name` and `location`.
2. Maps fields onto the `images` columns, coercing numerics and
   normalizing `imageDt` (user-supplied capture time) to a MySQL datetime.
3. Stamps `createDt` server-side in UTC.
4. Generates a unique S3 key (`images/<uuid><ext>`) and derives the object URL.
5. Inserts the row, then returns a pre-signed `PUT` URL (`201`) with the
   bucket, key, and expiry. Errors return `400`/`500` JSON.
6. Answers `OPTIONS` preflight requests for CORS.

### Query Service (`query/`)

`app.py` is a Flask app served by gunicorn on a private EC2 instance:

| Route | Behavior |
| --- | --- |
| `GET /health` | Liveness check |
| `GET /images` | Filtered listing of metadata rows |
| `GET /image?url=<s3url>` | Validates the stored URL, then 302-redirects to a short-lived pre-signed GET URL |

`/images` supports range filters (`latitudeMin/Max`, `longitudeMin/Max`,
`altitudeMin/Max`, `headingMin/Max`, `pitchMin/Max`, `rollMin/Max`,
`horizontalAccuracyMin/Max`), an exact match for any column via a `<field>Exact`
parameter (e.g. `latitudeExact`, `locationExact`, `imageDtExact`), datetime
filters (`imageDt`/`createDt` with `Since`/`Before` suffixes), substring filters
(`name`, `location`, `description`), an exact `s3url` match, a
`bbox=minLon,minLat,maxLon,maxLat` bounding box, `orderBy` + `order`, and
`limit`/`offset` paging. Numbers, datetimes, and `Decimal` values are
serialized with datetimes rendered as ISO-8601 UTC (`Z`).

`name`, `location`, and `description` also accept a `<field>Fuzzy` parameter for
typo-tolerant matching. Fuzzy terms are scored in the query service with a
`difflib` similarity ratio (whole-string plus a per-token best match) rather
than in SQL, so they rely on the other filters to narrow the rows first. A row
is kept only when it reaches the threshold for every fuzzy field (AND), results
are ranked by relevance (each image carries a `fuzzyScore`), and paging is
applied after ranking. Tune the threshold per request with `fuzzyThreshold`
(0..1, default `FUZZY_THRESHOLD` 0.6); the candidate set is capped at
`FUZZY_MAX_ROWS` (default 2000).

### Infrastructure (`templates/`)

`ImageVPC.yaml` is the network layer and is deployed first. It creates a
`10.0.0.0/16` VPC with DNS hostnames and support enabled, an internet gateway,
a NAT gateway (with an Elastic IP) for outbound traffic, public and private
route tables with their routes and subnet associations, and three subnets: a
public subnet (`10.0.0.0/24`) and a private subnet (`10.0.1.0/24`) in the
region's first availability zone, plus a second public subnet (`10.0.2.0/24`)
in the second availability zone so the load balancer has subnets in two AZs.
It exports `VpcId`, `PrivateSubnet`, and `PublicSubnetIds`, which supply the
query network parameters. Deploy it once with `./deploy.sh vpc` before the
first `all` or `query` deploy.

`ImageServiceInfrastructrure.yaml` is the deployed service stack. It provisions the
frontend S3 bucket plus origin access control, the Lambda and its Function URL,
the CloudFront distribution and routing rules, and the query tier (security
groups, EC2 instance, ALB, target group, listener). Key resources are exposed
as stack outputs (`FrontendURL`, `CaptureEndpoint`, `QueryAlbDnsName`,
`QueryImagesEndpoint`, and others).

`ImagePersistanceInfrastructrure.yaml` is an early draft of the storage layer
(bare S3 bucket + RDS instance) and is not part of the deployed stack.

## Deployment

`deploy.sh` deploys the network stack, builds the artifacts, deploys
`templates/ImageServiceInfrastructrure.yaml`, and publishes the frontend. The
stage argument selects how much of that it does:

| Stage | Builds | Deploys stack | Syncs frontend |
| --- | --- | --- | --- |
| `vpc` | nothing | network | no |
| `all` (default) | capture + query | service | yes |
| `lambda` | capture | service | no |
| `query` | query | service | no |
| `frontend` | nothing | no | yes |

```bash
# First setup: create the network stack the service stack depends on
./deploy.sh vpc

# Everything else: capture Lambda, query tier, and frontend
DB_HOST=<rds-endpoint> DB_PASSWORD=<password> ./deploy.sh all

# Just the capture Lambda after editing lambda_function.py
DB_HOST=<rds-endpoint> DB_PASSWORD=<password> ./deploy.sh lambda

# Just re-publish the static frontend
./deploy.sh frontend
```

`DB_HOST` and `DB_PASSWORD` are required for the stages that touch the query
tier. `QUERY_VPC_ID`, `QUERY_SUBNET_ID`, and `ALB_SUBNET_IDS` are read from the
network stack outputs (`VpcId`, `PrivateSubnet`, `PublicSubnetIds`) when they are
not set in the environment; an environment value wins over the stack output. If
the network stack does not exist and the variables are unset, the script stops
and tells you to run `./deploy.sh vpc` first. A stage that finds no existing
service stack is upgraded to a cold start, which builds both artifacts and
resolves the network the same way.

Artifacts are uploaded under content addressed keys (`capture-<hash>.zip`,
`query-<hash>.zip`) derived from the source files. That is what makes a
redeploy take effect: a changed key changes the Lambda code reference and the
query instance's user data, and the user data change replaces the instance so
it installs the new code. Replacing that instance leaves the query routes
unhealthy for a few minutes while it bootstraps, so the script waits for
`/health` afterwards (set `SKIP_HEALTH_WAIT=1` to skip).

`AWS_REGION`, `STACK_NAME`, `VPC_STACK_NAME`, `ARTIFACT_BUCKET`,
`LAMBDA_CODE_KEY`, `QUERY_CODE_KEY`, and other overrides are documented at the
top of `deploy.sh`.

## Database Definition

```sql
CREATE TABLE images (
    `s3url` VARCHAR(256) CHARACTER SET ascii NOT NULL,
    `name` VARCHAR(255) DEFAULT NULL,
    `location` VARCHAR(255) DEFAULT NULL,
    `latitude` DECIMAL(9,6) DEFAULT NULL,
    `longitude` DECIMAL(9,6) DEFAULT NULL,
    `altitude` DECIMAL(9,2) DEFAULT NULL,
    `horizontalAccuracy` DECIMAL(9,2) DEFAULT NULL,
    `imageDt` DATETIME DEFAULT NULL,
    `description` TEXT,
    `heading` DECIMAL(6,2) DEFAULT NULL,
    `pitch` DECIMAL(6,2) DEFAULT NULL,
    `roll` DECIMAL(6,2) DEFAULT NULL,
    `createDt` TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP,
    PRIMARY KEY (`s3url`),
  )
```
