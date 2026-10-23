# TinyLlama served by Ollama, with the model weights baked into the image
# so EC2/ECS doesn't need to download ~640 MB on every start.
FROM ollama/ollama:latest

ENV OLLAMA_HOST=0.0.0.0:11434

# Start the server briefly at build time, wait until it answers, pull the model, then stop it.
# (The base image has no pkill/ps, so stop it by PID.)
RUN ollama serve & pid=$!; \
    for i in $(seq 1 60); do ollama list >/dev/null 2>&1 && break; sleep 1; done; \
    ollama pull tinyllama; status=$?; \
    kill $pid; wait $pid 2>/dev/null; \
    exit $status

EXPOSE 11434
