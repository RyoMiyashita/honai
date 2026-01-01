# ========================================
# Stage 1: Composerの依存関係をインストール
# ========================================
FROM composer:2 AS composer

WORKDIR /app

# Composerファイルをコピー
COPY composer.json composer.lock ./

# 本番用の依存関係のみをインストール（dev依存関係を除く）
RUN composer install \
    --no-dev \
    --no-interaction \
    --no-progress \
    --no-scripts \
    --optimize-autoloader \
    --prefer-dist

# ========================================
# Stage 2: 本番イメージ
# ========================================
FROM php:8.4-fpm-alpine AS production

# 必要なパッケージとPHP拡張をインストール
RUN apk add --no-cache \
    nginx \
    supervisor \
    sqlite-dev \
    icu-dev \
    libzip-dev \
    && docker-php-ext-install \
    pdo_sqlite \
    pdo_mysql \
    intl \
    zip \
    opcache \
    bcmath

# PHP本番設定
RUN mv "$PHP_INI_DIR/php.ini-production" "$PHP_INI_DIR/php.ini"

# OPcache設定
COPY <<EOF /usr/local/etc/php/conf.d/opcache.ini
opcache.enable=1
opcache.memory_consumption=128
opcache.interned_strings_buffer=8
opcache.max_accelerated_files=10000
opcache.validate_timestamps=0
opcache.revalidate_freq=0
opcache.jit=1255
opcache.jit_buffer_size=64M
EOF

# PHP-FPM設定
RUN sed -i 's/pm.max_children = 5/pm.max_children = 50/' /usr/local/etc/php-fpm.d/www.conf \
    && sed -i 's/pm.start_servers = 2/pm.start_servers = 5/' /usr/local/etc/php-fpm.d/www.conf \
    && sed -i 's/pm.min_spare_servers = 1/pm.min_spare_servers = 5/' /usr/local/etc/php-fpm.d/www.conf \
    && sed -i 's/pm.max_spare_servers = 3/pm.max_spare_servers = 35/' /usr/local/etc/php-fpm.d/www.conf

WORKDIR /var/www/html

# Nginx設定をコピー
COPY docker/nginx.conf /etc/nginx/nginx.conf

# Supervisor設定をコピー
COPY docker/supervisord.conf /etc/supervisor/conf.d/supervisord.conf

# アプリケーションコードをコピー
COPY --chown=www-data:www-data . .

# Composer依存関係をコピー
COPY --from=composer --chown=www-data:www-data /app/vendor ./vendor

# 不要なファイルを削除
RUN rm -rf \
    node_modules \
    resources/js \
    resources/css \
    tests \
    docker \
    .git \
    .github \
    .env.example \
    phpunit.xml \
    vite.config.js \
    package.json \
    package-lock.json

# ストレージディレクトリの権限を設定
RUN mkdir -p storage/framework/{sessions,views,cache} \
    && mkdir -p storage/logs \
    && mkdir -p bootstrap/cache \
    && mkdir -p /var/log/supervisor \
    && chown -R www-data:www-data storage bootstrap/cache \
    && chmod -R 775 storage bootstrap/cache

EXPOSE 80

# ヘルスチェック
HEALTHCHECK --interval=30s --timeout=3s --start-period=5s --retries=3 \
    CMD wget --no-verbose --tries=1 --spider http://localhost/up || exit 1

# 起動スクリプト
COPY <<EOF /usr/local/bin/start.sh
#!/bin/sh
set -e

# キャッシュを生成（環境変数が設定された状態で実行）
php artisan config:cache
php artisan route:cache
php artisan view:cache

# マイグレーション実行（本番では慎重に）
if [ "\$RUN_MIGRATIONS" = "true" ]; then
    php artisan migrate --force
fi

# Supervisorを起動
exec /usr/bin/supervisord -c /etc/supervisor/conf.d/supervisord.conf
EOF

RUN chmod +x /usr/local/bin/start.sh

CMD ["/usr/local/bin/start.sh"]
