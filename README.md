# lemp-manager

Modular LEMP stack installer and WordPress site manager for **Debian 13**.  
**Linux · Nginx · MariaDB · PHP-FPM · Redis**

## Quick start

```bash
git clone <your-repo>
cd lemp-manager
chmod +x lemp.sh
sudo ./lemp.sh install
sudo ./lemp.sh site create example.com
sudo ./lemp.sh site ssl example.com
```

## Stack commands

| Command | Description |
|---|---|
| `./lemp.sh install` | Install full LEMP stack |
| `./lemp.sh install nginx php` | Install specific modules |
| `./lemp.sh status` | Show status of all components |
| `./lemp.sh upgrade [module]` | Upgrade all or one module |
| `./lemp.sh remove [module]` | Remove all or one module |
| `./lemp.sh config` | Show current config |

## Site commands

| Command | Description |
|---|---|
| `./lemp.sh site create example.com` | Full WordPress install |
| `./lemp.sh site ssl example.com` | Provision Let's Encrypt SSL |
| `./lemp.sh site list` | List all managed sites |
| `./lemp.sh site info example.com` | Show credentials & paths |
| `./lemp.sh site remove example.com` | Remove site, DB, and files |

## What `site create` does

1. DNS pre-check (warns if A record not set, doesn't block)
2. Creates web root `/var/www/example.com/`
3. Provisions MariaDB database + user with generated password
4. Creates Nginx vhost (HTTP; upgraded to HTTPS by `site ssl`)
5. Downloads WordPress via WP-CLI
6. Generates `wp-config.php` with Redis object cache constants
7. Runs `wp core install` (prompts for title, admin email)
8. Installs and enables **Redis Object Cache** plugin
9. Prints credentials (admin pass, DB pass) — save these!

## Modules

| Module | Package(s) | Notes |
|---|---|---|
| `nginx` | nginx | Global perf + security tuning included |
| `mariadb` | mariadb-server/client | WordPress-tuned, secure defaults applied |
| `php` | php8.x-fpm + extensions | OPcache JIT, imagick, redis extension |
| `redis` | redis-server | Unix socket, 128MB limit, allkeys-lru |
| `certbot` | certbot + nginx plugin | Auto-renewal via systemd timer |
| `firewall` | ufw + fail2ban | Ports 22/80/443; WP login brute force jail |

## Configuration

Edit `lemp.conf`:

```bash
PHP_VERSION="8.3"    # 8.2 | 8.3 | 8.4 (via Sury repo)
WEB_ROOT="/var/www"  # base path for all sites
```

## Architecture

```
lemp-manager/
├── lemp.sh          # Entry point & dispatcher
├── site.sh          # Multi-site WordPress orchestration
├── lemp.conf        # User configuration
├── lib/
│   ├── core.sh      # Logging, state, package helpers, DNS check
│   └── ui.sh        # Terminal output
└── modules/
    ├── nginx.sh      # Nginx + per-site vhost management
    ├── mariadb.sh    # MariaDB + per-site DB provisioning
    ├── php.sh        # PHP-FPM (shared pool, WordPress tuned)
    ├── redis.sh      # Redis (Unix socket, shared instance)
    ├── certbot.sh    # Let's Encrypt per-site SSL
    ├── firewall.sh   # UFW + fail2ban (WordPress + SSH jails)
    └── wordpress.sh  # WP-CLI download, install, Redis plugin
```

## State

```
/var/lib/lemp-manager/
├── installed.state          # Which modules are installed
└── sites/
    ├── example.com.conf     # Per-site credentials & metadata
    └── example2.com.conf
```

## Adding a module

1. Create `modules/yourmodule.sh`
2. Implement the four functions:
   - `module_install_yourmodule`
   - `module_remove_yourmodule`
   - `module_upgrade_yourmodule`
   - `module_status_yourmodule`
3. Add `yourmodule` to the `MODULES` array in `lemp.sh`

## Notes

- Requires **root** (`sudo`)
- PHP uses [Sury repo](https://packages.sury.org/php/) for multi-version support
- Redis runs on a **Unix socket** (faster than TCP for local PHP, no network exposure)
- Each site gets its own **MariaDB user** with least-privilege access
- `DISALLOW_FILE_EDIT` is set in `wp-config.php` by default (security best practice)
- Logs: `/var/log/lemp-manager.log`
