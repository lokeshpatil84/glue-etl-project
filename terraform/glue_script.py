import sys
from awsglue.transforms import *
from awsglue.utils import getResolvedOptions
from awsglue.context import GlueContext
from pyspark.context import SparkContext
from awsglue.job import Job
from pyspark.sql.functions import col

## @params: [JOB_NAME]
args = getResolvedOptions(sys.argv, ['JOB_NAME', 'raw_bucket', 'processed_bucket'])

sc = SparkContext()
glueContext = GlueContext(sc)
spark = glueContext.spark_session
job = Job(glueContext)
job.init(args['JOB_NAME'], args)

# Read raw CSV
raw_bucket = args['raw_bucket']
df = spark.read.option("header", "true").option("inferSchema", "true").csv(f"s3://{raw_bucket}/input/*.csv")

# Simple ETL: Drop nulls, filter age > 18, cast types
cleaned_df = df.na.drop().filter(col("age").cast("int") > 18).select(
    col("name").cast("string"),
    col("age").cast("int"),
    col("city").cast("string")
)

# Write to processed
processed_bucket = args['processed_bucket']
cleaned_df.coalesce(1).write.mode("overwrite").option("header", "true").csv(f"s3://{processed_bucket}/cleaned/")

# Commit
job.commit()