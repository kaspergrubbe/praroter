#!/bin/bash
redis-cli --ldb --eval lib/praroter/filly_bucket/filly_bucket.lua filly_bucket.api.user_42.bucket_level filly_bucket.api.user_42.last_updated , 10000 250 1000
