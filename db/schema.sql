-- Schema for the image metadata database.
--
-- Applied by deploy.sh over SSM (see db/apply_schema.py) on every service
-- stage deploy and on demand via './deploy.sh schema'. Every statement must be
-- idempotent because this file is re-applied on each deploy.

CREATE TABLE IF NOT EXISTS images (
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
    PRIMARY KEY (`s3url`)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4;
