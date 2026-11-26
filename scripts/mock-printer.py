#!/usr/bin/env python3
"""
Mock worker simulant stand-print-svc (Windows) sur Linux/NixOS.

Implémente exactement le contrat RabbitMQ du code C# :
- Consomme la queue durable `print.jobs` :
    { "jobId": "uuid", "photos": [{ "photoStorageKey": "full/...", "copies": 1 }], "startFromIndex": 0 }
- Publie sur la queue durable `print.status` (exchange par défaut "") :
    { "jobId": "uuid", "status": "printing|done|error", "printed": 1, "total": 3, "error": null }
"""

import json
import logging
import os
import random
import signal
import sys
import time
import pika

logging.basicConfig(
    level=logging.INFO,
    format="%(asctime)s [mock-printer] %(levelname)s %(message)s",
    stream=sys.stdout,
)
log = logging.getLogger("mock-printer")

BROKER_HOST = os.environ.get("BROKER_HOST", "127.0.0.1")
BROKER_PORT = int(os.environ.get("BROKER_PORT", "5672"))
BROKER_USER = os.environ.get("BROKER_USER", "guest")
BROKER_PASS = os.environ.get("BROKER_PASS", "guest")
JOBS_QUEUE = os.environ.get("JOBS_QUEUE", "print.jobs")
RESULTS_QUEUE = os.environ.get("RESULTS_QUEUE", "print.status")
DELAY_SECONDS = float(os.environ.get("MOCK_PRINT_DELAY_SECONDS", "2.0"))
ERROR_RATE = float(os.environ.get("MOCK_PRINT_ERROR_RATE", "0.0"))

_stopping = False


def _handle_signal(signum, _frame):
    global _stopping
    log.info("Signal %s reçu, arrêt du mock-printer...", signum)
    _stopping = True


signal.signal(signal.SIGTERM, _handle_signal)
signal.signal(signal.SIGINT, _handle_signal)


def publish_status(channel, job_id: str, status: str, printed: int, total: int, error=None):
    payload = {
        "jobId": job_id,
        "status": status,
        "printed": printed,
        "total": total,
        "error": error,
    }
    body = json.dumps(payload).encode("utf-8")
    channel.basic_publish(
        exchange="",
        routing_key=RESULTS_QUEUE,
        body=body,
        properties=pika.BasicProperties(content_type="application/json", delivery_mode=2),
    )
    log.info("-> print.status: job=%s status=%s printed=%d/%d error=%s", job_id, status, printed, total, error)


def process_job(channel, body: bytes):
    try:
        job = json.loads(body.decode("utf-8"))
    except Exception as exc:
        log.error("Impossible de désérialiser le message print.jobs : %s", exc)
        return

    job_id = job.get("jobId")
    photos = job.get("photos") or []
    start_from = int(job.get("startFromIndex") or 0)
    total = len(photos)

    if not job_id or start_from < 0 or start_from > total:
        log.error("Job invalide : %s", job)
        return

    log.info("Job reçu : %s (%d photo(s), startFromIndex=%d)", job_id, total, start_from)
    printed = start_from
    has_error = False

    for photo in photos[start_from:]:
        if _stopping:
            return
        key = photo.get("photoStorageKey", "unknown")
        copies = max(1, int(photo.get("copies") or 1))
        log.info("Impression simulée : %s (x%d) ...", key, copies)
        time.sleep(DELAY_SECONDS * copies)

        if ERROR_RATE > 0.0 and random.random() < ERROR_RATE:
            has_error = True
            publish_status(
                channel,
                job_id=job_id,
                status="error",
                printed=printed,
                total=total,
                error=f"Erreur simulée pendant l'impression de {key}",
            )
            continue

        printed += 1
        publish_status(
            channel,
            job_id=job_id,
            status="printing",
            printed=printed,
            total=total,
        )

    if not has_error:
        publish_status(
            channel,
            job_id=job_id,
            status="done",
            printed=printed,
            total=total,
        )


def main():
    backoff = 2
    credentials = pika.PlainCredentials(BROKER_USER, BROKER_PASS)
    params = pika.ConnectionParameters(
        host=BROKER_HOST,
        port=BROKER_PORT,
        credentials=credentials,
        heartbeat=60,
        blocked_connection_timeout=30,
    )

    while not _stopping:
        connection = None
        try:
            log.info("Connexion à RabbitMQ %s:%d ...", BROKER_HOST, BROKER_PORT)
            connection = pika.BlockingConnection(params)
            channel = connection.channel()
            channel.queue_declare(queue=JOBS_QUEUE, durable=True)
            channel.queue_declare(queue=RESULTS_QUEUE, durable=True)
            channel.basic_qos(prefetch_count=1)
            backoff = 2
            log.info("Connecté. En attente de jobs sur '%s'...", JOBS_QUEUE)

            for method, _props, body in channel.consume(queue=JOBS_QUEUE, auto_ack=False, inactivity_timeout=1.0):
                if _stopping:
                    break
                if method is None:
                    continue
                channel.basic_ack(delivery_tag=method.delivery_tag)
                process_job(channel, body)
        except Exception as exc:
            if _stopping:
                break
            log.warning("Connexion RabbitMQ interrompue (%s). Nouvelle tentative dans %ds...", exc, backoff)
            time.sleep(backoff)
            backoff = min(backoff * 2, 30)
        finally:
            if connection and connection.is_open:
                try:
                    connection.close()
                except Exception:
                    pass

    log.info("mock-printer arrêté.")


if __name__ == "__main__":
    main()
