# Nextcloud plus ffmpeg: video thumbnails and Memories transcoding.
# To update Nextcloud: change NEXTCLOUD_IMAGE in compose.yaml (pinned digest),
# then `docker compose build --pull app cron`. The pre-update.sh backup still applies.
ARG NEXTCLOUD_IMAGE
FROM ${NEXTCLOUD_IMAGE}
RUN apt-get update \
 && apt-get install -y --no-install-recommends ffmpeg \
 && rm -rf /var/lib/apt/lists/*
