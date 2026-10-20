# Z-Push 2.7.6 IMAP backend — php:8.3-apache
# PHP 8.4 removed the bundled imap extension; stay on 8.3 so docker-php-ext-install imap works.
# Extensions:
#   intl            Utils::FormatDateUtc() calls datefmt_create() for every mail date (fatal without it)
#   sysvsem/sysvshm IpcSharedMemoryProvider (PingTracking, LoopDetection, TopCollector)
#   pcntl           z-push-top
# Build deps are not purged, so runtime libs (libicu72, libc-client2007e, ...) stay in the image.
# Refs: https://github.com/Z-Hub/Z-Push/releases/tag/2.7.6
#       https://github.com/Z-Hub/Z-Push/discussions/97 (datefmt_create fatal without intl)
#       https://www.php.net/manual/en/imap.installation.php (8.4 → PECL)

FROM php:8.3-apache-bookworm

ARG ZPUSH_VERSION=2.7.6

ENV DEBIAN_FRONTEND=noninteractive \
    ZPUSH_HOME=/usr/share/z-push \
    APACHE_DOCUMENT_ROOT=/var/www/html

RUN apt-get update && apt-get install -y --no-install-recommends \
        libc-client-dev \
        libkrb5-dev \
        libonig-dev \
        libicu-dev \
        libxml2-dev \
        zlib1g-dev \
        libzip-dev \
        unzip \
        patch \
        tzdata \
        ca-certificates \
        curl \
    && docker-php-ext-configure imap --with-kerberos --with-imap-ssl \
    && docker-php-ext-install -j"$(nproc)" imap soap mbstring opcache intl sysvsem sysvshm pcntl \
    && a2enmod alias headers \
    && rm -rf /var/lib/apt/lists/*

# Download Z-Push release, apply our patches (build fails if a patch does not apply cleanly),
# make code root-owned and read-only for the web user.
COPY patches/ /tmp/patches/
RUN curl -fsSL "https://github.com/Z-Hub/Z-Push/archive/refs/tags/${ZPUSH_VERSION}.tar.gz" \
        -o /tmp/z-push.tar.gz \
    && tar -xzf /tmp/z-push.tar.gz -C /tmp \
    && cd "/tmp/Z-Push-${ZPUSH_VERSION}" \
    && for p in /tmp/patches/*.patch; do \
         echo "applying $p"; patch -p1 --forward --fuzz=0 --no-backup-if-mismatch < "$p" || exit 1; \
       done \
    && mkdir -p "${ZPUSH_HOME}" \
    && cp -a "/tmp/Z-Push-${ZPUSH_VERSION}/src/." "${ZPUSH_HOME}/" \
    && for f in config.php backend/imap/config.php autodiscover/config.php; do \
         cp "${ZPUSH_HOME}/$f" "${ZPUSH_HOME}/$f.dist"; \
       done \
    && chown -R root:root "${ZPUSH_HOME}" \
    && find "${ZPUSH_HOME}" -type d -exec chmod 755 {} + \
    && find "${ZPUSH_HOME}" -type f -exec chmod 644 {} + \
    && mkdir -p /var/lib/z-push /var/log/z-push \
    && chown www-data:www-data /var/lib/z-push /var/log/z-push \
    && rm -rf /tmp/z-push.tar.gz "/tmp/Z-Push-${ZPUSH_VERSION}" /tmp/patches

# Apache: aliases for EAS + Autodiscover, long timeouts, hardening
COPY apache/z-push.conf apache/z-push-autodiscover.conf apache/z-push-security.conf /etc/apache2/conf-available/
RUN printf '%s\n' 'ServerName localhost' 'Timeout 1800' > /etc/apache2/conf-available/z-push-timeout.conf \
    && a2enconf z-push z-push-autodiscover z-push-security z-push-timeout \
    && sed -i 's#^\([[:space:]]*CustomLog .* combined\)$#\1 env=!zpush_healthcheck#' /etc/apache2/sites-available/000-default.conf \
    && grep -q 'env=!zpush_healthcheck' /etc/apache2/sites-available/000-default.conf \
    && apache2ctl -t

# PHP: long-lived Ping, hardening, opcache (configs never change after start)
RUN printf '%s\n' \
        'max_execution_time = 1800' \
        'max_input_time = 1800' \
        'upload_max_filesize = 50M' \
        'post_max_size = 50M' \
        'expose_php = Off' \
        'log_errors = On' \
        'display_errors = Off' \
        'error_reporting = E_ALL & ~E_DEPRECATED & ~E_STRICT' \
        > /usr/local/etc/php/conf.d/z-push.ini \
    && printf '%s\n' \
        'opcache.interned_strings_buffer = 16' \
        'opcache.max_accelerated_files = 10000' \
        'opcache.validate_timestamps = 0' \
        > /usr/local/etc/php/conf.d/z-push-opcache.ini

COPY scripts/docker-entrypoint.sh /usr/local/bin/docker-entrypoint.sh
COPY scripts/z-push-admin scripts/z-push-top /usr/local/bin/
COPY scripts/zpush-setconfig.php /usr/local/lib/z-push-docker/zpush-setconfig.php
RUN chmod 755 /usr/local/bin/docker-entrypoint.sh /usr/local/bin/z-push-admin /usr/local/bin/z-push-top \
    && chmod 644 /usr/local/lib/z-push-docker/zpush-setconfig.php

# Minimal docroot (aliases hit ZPUSH_HOME directly)
RUN echo '<?php header("Location: /Microsoft-Server-ActiveSync");' > /var/www/html/index.php

VOLUME ["/var/lib/z-push", "/var/log/z-push"]
EXPOSE 80

# Unauthenticated request must reach Z-Push and get 401 (500 = PHP/config error)
HEALTHCHECK --interval=30s --timeout=10s --start-period=20s --retries=3 \
    CMD code=$(curl -s -o /dev/null -A zpush-healthcheck -w '%{http_code}' http://127.0.0.1/Microsoft-Server-ActiveSync) && [ "$code" = "401" ] || exit 1

ENTRYPOINT ["/usr/local/bin/docker-entrypoint.sh"]
CMD ["apache2-foreground"]
