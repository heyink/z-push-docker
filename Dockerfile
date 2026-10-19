# Z-Push 2.7.6 IMAP backend — php:8.3-apache
# PHP 8.4 removed the bundled imap extension; stay on 8.3 so docker-php-ext-install imap works.
# Refs: https://github.com/Z-Hub/Z-Push/releases/tag/2.7.6
#       https://github.com/Z-Hub/Z-Push/discussions/121 (prefer PHP 8.x)
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
        libxml2-dev \
        zlib1g-dev \
        libzip-dev \
        unzip \
        ca-certificates \
        curl \
    && docker-php-ext-configure imap --with-kerberos --with-imap-ssl \
    && docker-php-ext-install -j"$(nproc)" imap soap mbstring opcache \
    && a2enmod alias rewrite headers \
    && rm -rf /var/lib/apt/lists/*

# Download Z-Push release
RUN curl -fsSL "https://github.com/Z-Hub/Z-Push/archive/refs/tags/${ZPUSH_VERSION}.tar.gz" \
        -o /tmp/z-push.tar.gz \
    && tar -xzf /tmp/z-push.tar.gz -C /tmp \
    && mkdir -p "${ZPUSH_HOME}" \
    && cp -a "/tmp/Z-Push-${ZPUSH_VERSION}/src/." "${ZPUSH_HOME}/" \
    && mkdir -p /var/lib/z-push /var/log/z-push \
    && chown -R www-data:www-data /var/lib/z-push /var/log/z-push "${ZPUSH_HOME}" \
    && rm -rf /tmp/z-push.tar.gz "/tmp/Z-Push-${ZPUSH_VERSION}"

# Apache aliases for EAS + Autodiscover
COPY apache/z-push.conf /etc/apache2/conf-available/z-push.conf
COPY apache/z-push-autodiscover.conf /etc/apache2/conf-available/z-push-autodiscover.conf
RUN a2enconf z-push z-push-autodiscover \
    && printf '%s\n' \
        'ServerName localhost' \
        'Timeout 1800' \
        > /etc/apache2/conf-available/z-push-timeout.conf \
    && a2enconf z-push-timeout

# PHP runtime tuned for long-lived PING
RUN printf '%s\n' \
        'memory_limit = 256M' \
        'max_execution_time = 1800' \
        'max_input_time = 1800' \
        'upload_max_filesize = 50M' \
        'post_max_size = 50M' \
        'log_errors = On' \
        'error_log = /var/log/z-push/php-error.log' \
        > /usr/local/etc/php/conf.d/z-push.ini

COPY scripts/docker-entrypoint.sh /usr/local/bin/docker-entrypoint.sh
RUN chmod +x /usr/local/bin/docker-entrypoint.sh

# Minimal docroot (aliases hit ZPUSH_HOME directly)
RUN echo '<?php header("Location: /Microsoft-Server-ActiveSync");' > /var/www/html/index.php

VOLUME ["/var/lib/z-push", "/var/log/z-push"]
EXPOSE 80

ENTRYPOINT ["/usr/local/bin/docker-entrypoint.sh"]
CMD ["apache2-foreground"]
