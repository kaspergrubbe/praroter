#!/bin/bash
redis-cli --ldb --eval lib/praroter/filly_bucket.lua filly_bucket.api.user:42.bucket_level filly_bucket.api.user:42.last_updated , 5000 100 1000
