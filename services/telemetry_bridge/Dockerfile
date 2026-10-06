FROM python:3.12-alpine

WORKDIR /app

# numpy + Pillow draw the map tiles (tiles.py)
RUN pip install --no-cache-dir numpy==2.* pillow==11.*

COPY server.py tiles.py /app/

EXPOSE 2310

ENTRYPOINT ["python3", "-u", "/app/server.py"]
