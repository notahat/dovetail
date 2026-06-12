# Dovetail in a container: builds the binary and drops you into the
# REPL with the demo tables already seeded. Meant for trying the
# database out, not for production use.
#
#   docker build -t dovetail .
#   docker run -it --rm dovetail          # relational-algebra REPL
#   docker run -it --rm dovetail --sql    # SQL REPL
#
# Both forms start with the demo `users` and `orders` tables seeded.
# Add `-v dovetail-data:/data` to keep your data between runs.

# ---- Build stage -----------------------------------------------------
FROM ocaml/opam:debian-12-ocaml-5.2 AS builder

# The OCaml lmdb binding links the system LMDB library rather than
# bundling it, so install the headers and library (plus pkg-config,
# which its build uses to locate them) before resolving opam deps.
RUN sudo apt-get update \
 && sudo apt-get install -y --no-install-recommends liblmdb-dev pkg-config \
 && sudo rm -rf /var/lib/apt/lists/*

WORKDIR /home/opam/dovetail

# Resolve dependencies in their own layer so editing source does not
# invalidate the slow dependency install. The opam file is generated
# from dune-project, so both describe the dependency set; copying just
# these two keeps the cache valid until the dependencies themselves
# change. liblmdb-dev is installed above, so opam need not manage it.
COPY --chown=opam:opam dune-project dovetail.opam ./
RUN opam update --yes \
 && opam install . --deps-only --assume-depexts --yes

# Build the REPL binary against the full source tree.
COPY --chown=opam:opam . .
RUN opam exec -- dune build bin/main.exe

# ---- Runtime stage ---------------------------------------------------
FROM debian:12-slim AS runtime

# The binary links liblmdb dynamically; ship the runtime library only,
# not the -dev headers. Both stages are Debian 12, so the glibc the
# binary was built against matches.
RUN apt-get update \
 && apt-get install -y --no-install-recommends liblmdb0 \
 && rm -rf /var/lib/apt/lists/*

COPY --from=builder \
  /home/opam/dovetail/_build/default/bin/main.exe \
  /usr/local/bin/dovetail

# The LMDB environment lives here; expose it as a volume so a mounted
# directory can outlive the container.
VOLUME /data

# Seed and read the demo tables from /data. Extra arguments are
# appended, so `docker run -it dovetail --sql` runs
# `dovetail --demo-data /data --sql`. Re-seeding an already-seeded
# directory is a no-op, so this stays correct across restarts.
ENTRYPOINT ["dovetail", "--demo-data", "/data"]
