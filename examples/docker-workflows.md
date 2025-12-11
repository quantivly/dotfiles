# Docker Workflow Examples

This document demonstrates common Docker workflows using the aliases configured in this dotfiles repository.

## Quick Reference

| Workflow | Key Commands | Description |
|----------|--------------|-------------|
| Start Services | `dcup` → `dps` → `dclogs` | Start and monitor containers |
| Debug Container | `dps` → `dex` → explore | Access running container shell |
| View Logs | `dlog` / `dlogf` / `dclogs` | Check container logs |
| Cleanup | `dstop` → `drm` → `dclean` | Stop and remove containers |
| Full Reset | `dstopa` → `drm` → `dprune` | Complete cleanup (USE WITH CAUTION) |

---

## Docker Compose Workflows

### Start and Monitor Services

Standard workflow for running services defined in `docker-compose.yml`.

#### Step-by-Step

```bash
# 1. Start all services in background
dcup
# Runs: docker compose up -d
# -d flag runs in detached mode (background)

# 2. Check running containers
dps
# Shows: Container ID, Name, Status, Ports

# 3. Follow logs in real-time
dclogs
# Runs: docker compose logs -f
# Ctrl+C to stop following (containers keep running)

# 4. Check specific service logs
docker compose logs -f web
# or
dlog web -f

# 5. Check service status
dcps
# Shows status of all compose services
```

#### Quick Version

```bash
dcup && dps && dclogs
```

### Stop Services

```bash
# Stop all compose services (graceful shutdown)
dcdown
# Runs: docker compose down

# Stop and remove volumes (deletes data!)
docker compose down -v

# Stop without removing containers
docker compose stop
```

---

## Container Lifecycle Management

### Start Individual Containers

```bash
# Start a specific container
docker start myapp

# Start and attach to container output
docker start -a myapp

# Start all stopped containers
docker start $(docker ps -aq)
```

### Stop Containers

```bash
# Stop specific container (graceful, 10s timeout)
docker stop myapp

# Stop all running containers
dstop
# Runs: docker stop $(docker ps -q)

# Stop ALL containers (including stopped ones)
dstopa
# Runs: docker stop $(docker ps -aq)

# Force stop (immediate kill)
docker kill myapp
```

### Restart Containers

```bash
# Restart specific container
docker restart myapp

# Restart all running containers
docker restart $(docker ps -q)

# Restart compose services
docker compose restart

# Restart specific compose service
docker compose restart web
```

---

## Debugging and Inspection

### Access Container Shell

```bash
# Access running container with bash
dex myapp bash
# Runs: docker exec -it myapp bash
# -i = interactive, -t = terminal

# If bash not available, use sh
dex myapp sh

# Access as root user
docker exec -it -u root myapp bash

# Access with specific working directory
docker exec -it -w /app myapp bash
```

### View Container Logs

```bash
# View recent logs
dlog myapp
# Runs: docker logs myapp

# Follow logs in real-time
dlogf myapp
# Runs: docker logs -f myapp

# View last 100 lines
dlog myapp --tail 100

# View logs since specific time
dlog myapp --since 30m  # Last 30 minutes
dlog myapp --since "2025-01-01T10:00:00"

# View logs with timestamps
dlog myapp --timestamps
```

### Inspect Container Details

```bash
# View all container details (JSON)
docker inspect myapp

# Get specific information
docker inspect -f '{{.State.Status}}' myapp
docker inspect -f '{{.NetworkSettings.IPAddress}}' myapp
docker inspect -f '{{range .NetworkSettings.Networks}}{{.IPAddress}}{{end}}' myapp

# View container processes
docker top myapp

# View resource usage (live stats)
docker stats myapp
# or all containers:
docker stats

# View port mappings
docker port myapp
```

### Check Container Health

```bash
# View health status
docker inspect -f '{{.State.Health.Status}}' myapp

# View health check logs
docker inspect -f '{{json .State.Health}}' myapp | jq

# Manual health check command
docker exec myapp curl -f http://localhost:8080/health
```

---

## Image Management

### List and Inspect Images

```bash
# List all images
di
# Runs: docker images

# List with digests
docker images --digests

# List specific repository
docker images myapp

# View image history (layers)
docker history myapp:latest

# Inspect image details
docker inspect myapp:latest
```

### Build Images

```bash
# Build from Dockerfile in current directory
docker build -t myapp:latest .

# Build with build args
docker build --build-arg ENV=production -t myapp:prod .

# Build with no cache
docker build --no-cache -t myapp:latest .

# Build specific target in multi-stage build
docker build --target production -t myapp:prod .

# Build with progress output
docker build --progress=plain -t myapp:latest .
```

### Pull and Push Images

```bash
# Pull image from registry
docker pull nginx:latest

# Pull specific platform
docker pull --platform linux/amd64 nginx:latest

# Push to registry
docker push myregistry.com/myapp:latest

# Tag for different registry
docker tag myapp:latest myregistry.com/myapp:v1.0
docker push myregistry.com/myapp:v1.0
```

### Remove Images

```bash
# Remove specific image
docker rmi myapp:old

# Remove unused images
docker image prune

# Remove all unused images (not just dangling)
docker image prune -a

# Force remove (even if containers using it exist)
docker rmi -f myapp:latest

# Remove ALL images (CAUTION!)
drmi
# Runs: docker rmi $(docker images -q)
```

---

## Cleanup Workflows

### Basic Cleanup

```bash
# 1. Stop all running containers
dstop

# 2. Remove all stopped containers
drm
# Runs: docker rm $(docker ps -aq)

# 3. Remove unused images, networks, volumes
dclean
# Runs: docker system prune -f
```

### Full Cleanup (CAUTION!)

```bash
# WARNING: This removes EVERYTHING including volumes!
dprune
# Runs: docker system prune -af --volumes

# What this removes:
# - All stopped containers
# - All networks not used by containers
# - All images without containers
# - All build cache
# - ALL VOLUMES (data loss!)
```

### Selective Cleanup

```bash
# Remove only stopped containers
docker container prune

# Remove only dangling images
docker image prune

# Remove only unused volumes
docker volume prune

# Remove only unused networks
docker network prune

# Remove everything except volumes
docker system prune -a

# Remove build cache
docker builder prune
```

### Cleanup by Filter

```bash
# Remove containers older than 24 hours
docker container prune --filter "until=24h"

# Remove images older than 7 days
docker image prune -a --filter "until=168h"

# Remove stopped containers with specific label
docker container prune --filter "label=temp=true"
```

---

## Docker Compose Advanced

### Scale Services

```bash
# Scale specific service to 3 instances
docker compose up -d --scale web=3

# Scale multiple services
docker compose up -d --scale web=3 --scale worker=5
```

### View Service Logs

```bash
# Logs from all services
dclogs

# Logs from specific service
docker compose logs -f web

# Last 50 lines from each service
docker compose logs --tail 50

# Logs since timestamp
docker compose logs --since "2025-01-01T10:00:00"
```

### Execute Commands in Services

```bash
# Run command in running service
docker compose exec web bash

# Run as specific user
docker compose exec -u root web bash

# Run command without TTY (for scripts)
docker compose exec -T web python manage.py migrate

# Run one-off command (starts new container)
docker compose run web python manage.py createsuperuser
```

### Update Services

```bash
# Pull latest images
docker compose pull

# Rebuild and restart services
docker compose up -d --build

# Force recreate containers
docker compose up -d --force-recreate

# Update specific service
docker compose up -d --build web
```

---

## Networking

### List Networks

```bash
# List all networks
docker network ls

# Inspect network
docker network inspect mynetwork

# List containers on network
docker network inspect mynetwork -f '{{range .Containers}}{{.Name}} {{end}}'
```

### Create Networks

```bash
# Create bridge network
docker network create mynetwork

# Create network with subnet
docker network create --subnet=172.18.0.0/16 mynetwork

# Create overlay network (Swarm)
docker network create --driver overlay mynetwork
```

### Connect Containers

```bash
# Connect container to network
docker network connect mynetwork mycontainer

# Disconnect
docker network disconnect mynetwork mycontainer

# Connect with alias
docker network connect --alias db mynetwork postgres
```

---

## Volume Management

### List and Inspect Volumes

```bash
# List all volumes
docker volume ls

# Inspect volume
docker volume inspect myvolume

# Find which containers use volume
docker ps -a --filter volume=myvolume
```

### Create and Remove Volumes

```bash
# Create named volume
docker volume create mydata

# Remove volume
docker volume rm mydata

# Remove all unused volumes
docker volume prune
```

### Backup and Restore Volumes

```bash
# Backup volume to tar file
docker run --rm -v mydata:/data -v $(pwd):/backup \
  ubuntu tar czf /backup/mydata.tar.gz -C /data .

# Restore volume from tar file
docker run --rm -v mydata:/data -v $(pwd):/backup \
  ubuntu tar xzf /backup/mydata.tar.gz -C /data
```

---

## Troubleshooting

### Container Won't Start

```bash
# View logs for errors
dlog mycontainer

# Check exit code
docker inspect -f '{{.State.ExitCode}}' mycontainer

# Try starting in foreground to see output
docker start -a mycontainer

# Override entrypoint to debug
docker run -it --entrypoint bash myimage
```

### Container Running But Not Responding

```bash
# Check if process is running
docker top mycontainer

# Check resource usage
docker stats mycontainer

# Access shell to investigate
dex mycontainer bash

# Check network connectivity
docker exec mycontainer ping google.com
docker exec mycontainer curl localhost:8080
```

### Port Already in Use

```bash
# Find which process uses port 8080
sudo lsof -i :8080
# or
sudo netstat -tulpn | grep 8080

# Kill process using port
sudo kill -9 <PID>

# Or change port in docker-compose.yml
ports:
  - "8081:8080"  # Map to different host port
```

### Permission Denied Errors

```bash
# Run as root
docker exec -it -u root mycontainer bash

# Fix ownership in container
docker exec -u root mycontainer chown -R appuser:appuser /app

# Check volume permissions
docker run --rm -v myvolume:/data ubuntu ls -la /data
```

### Out of Disk Space

```bash
# Check Docker disk usage
docker system df

# Detailed breakdown
docker system df -v

# Clean up aggressively
dprune  # CAUTION: Removes volumes!

# Or selective cleanup
dclean  # Preserves volumes
```

### Container Keeps Restarting

```bash
# Check logs for crash reason
dlog mycontainer --tail 100

# View last container status
docker inspect -f '{{.State.Status}}' mycontainer

# Disable restart policy temporarily
docker update --restart=no mycontainer

# Check health check failures
docker inspect -f '{{json .State.Health}}' mycontainer
```

---

## Best Practices

### 1. Use Docker Compose for Multi-Container Apps

```yaml
# docker-compose.yml
version: '3.8'
services:
  web:
    build: .
    ports:
      - "8000:8000"
    depends_on:
      - db
    environment:
      - DATABASE_URL=postgresql://db:5432/myapp

  db:
    image: postgres:14
    volumes:
      - dbdata:/var/lib/postgresql/data
    environment:
      - POSTGRES_PASSWORD=secret

volumes:
  dbdata:
```

### 2. Name Your Containers

```bash
# Bad: docker run -d nginx
# Good: docker run -d --name web nginx

# Makes management easier:
dlog web
dex web bash
docker stop web
```

### 3. Use Health Checks

```dockerfile
# In Dockerfile
HEALTHCHECK --interval=30s --timeout=3s --retries=3 \
  CMD curl -f http://localhost:8080/health || exit 1
```

```yaml
# In docker-compose.yml
services:
  web:
    healthcheck:
      test: ["CMD", "curl", "-f", "http://localhost:8080/health"]
      interval: 30s
      timeout: 3s
      retries: 3
```

### 4. Use .dockerignore

```bash
# .dockerignore
node_modules
*.log
.git
.env
.DS_Store
```

### 5. Multi-Stage Builds for Smaller Images

```dockerfile
# Build stage
FROM node:18 AS builder
WORKDIR /app
COPY package*.json ./
RUN npm ci
COPY . .
RUN npm run build

# Production stage
FROM node:18-slim
WORKDIR /app
COPY --from=builder /app/dist ./dist
COPY --from=builder /app/node_modules ./node_modules
CMD ["node", "dist/main.js"]
```

### 6. Never Store Secrets in Images

```bash
# Bad: ENV API_KEY=secret123

# Good: Pass at runtime
docker run -e API_KEY=secret123 myapp

# Better: Use secrets file
docker run --env-file .env myapp

# Best: Use Docker secrets (Swarm) or external secret management
```

---

## Docker Aliases Quick Reference

Configured in `~/.dotfiles/zsh/zshrc.aliases`:

| Alias | Command | Description |
|-------|---------|-------------|
| `dps` | `docker ps` | List running containers |
| `dpsa` | `docker ps -a` | List all containers |
| `di` | `docker images` | List images |
| `dlog` | `docker logs` | View container logs |
| `dlogf` | `docker logs -f` | Follow container logs |
| `dex` | `docker exec -it` | Execute in container |
| `dstop` | `docker stop $(docker ps -q)` | Stop all running |
| `dstopa` | `docker stop $(docker ps -aq)` | Stop all containers |
| `drm` | `docker rm $(docker ps -aq)` | Remove all containers |
| `drmi` | `docker rmi $(docker images -q)` | Remove all images |
| `dprune` | `docker system prune -af --volumes` | Full cleanup |
| `dclean` | `docker system prune -f` | Basic cleanup |
| `dcp` | `docker compose` | Docker compose shortcut |
| `dcup` | `docker compose up -d` | Start services |
| `dcdown` | `docker compose down` | Stop services |
| `dclogs` | `docker compose logs -f` | Follow compose logs |
| `dcps` | `docker compose ps` | List compose services |

---

## Common Patterns

### Development Environment

```bash
# Start development stack
dcup

# Watch logs
dclogs

# Access database
dex db psql -U postgres

# Run migrations
docker compose exec web python manage.py migrate

# Access app shell
dex web bash

# Restart service after code changes
docker compose restart web

# Stop when done
dcdown
```

### Production Deployment

```bash
# Pull latest images
docker compose pull

# Update services with zero-downtime
docker compose up -d --no-deps --build web

# Check health
docker compose ps
docker compose logs -f web

# Rollback if issues
docker compose down
docker compose up -d --scale web=3
```

### Testing in Clean Environment

```bash
# Stop and remove everything
dcdown -v

# Rebuild fresh
docker compose build --no-cache

# Start and test
dcup
docker compose exec web pytest

# Cleanup
dcdown -v
```
