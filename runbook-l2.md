# Runbook L2 - Podinfo su Kubernetes

Questo documento descrive le procedure operative standard (SOP) per la diagnosi e la risoluzione di anomalie relative al deploy di Podinfo su un cluster Kubernetes locale (Kind). L'approccio seguito è quello del Supporto di Secondo Livello (L2): raccolta evidenze, formulazione ipotesi, applicazione fix o rollback, e successiva escalation se necessario.

## 1. Controlli Iniziali e Comandi Diagnostici

Prima di indagare su un problema specifico, eseguire sempre questi controlli per verificare lo stato generale dell'applicazione:

*   **Stato del cluster:** `kubectl get nodes` (Atteso: `kind-control-plane` in stato `Ready`).
*   **Stato dei Pod:** `kubectl get pods -n demo` (Atteso: Pod in stato `Running 1/1`).
*   **Eventi del Pod:** `kubectl describe pod -n demo -l app=podinfo` (Fondamentale: controllare sempre la sezione `Events` in fondo).
*   **Log dell'applicazione:** `kubectl logs -n demo -l app=podinfo --tail=50` (Se il Pod è in CrashLoopBackOff, usare `--previous` per leggere i log del container crashato prima che venisse riavviato).
*   **Endpoint di rete:** `kubectl get endpointslice -n demo -l kubernetes.io/service-name=podinfo` (Verificare che l'EndpointSlice contenga gli indirizzi dei Pod pronti; in caso contrario, controllare selector e readiness).

---

## 2. Scenari di Errore e Risoluzione

### Scenario 1: ImagePullBackOff (Immagine non trovata)
*   **Riproduzione:** Modificare il tag dell'immagine nel manifest con uno inesistente e riapplicare.
    ```bash
    kubectl set image deployment/podinfo podinfo=stefanprodan/podinfo:6.4.0-inesistente -n demo
    ```
*   **Sintomo:** Il nuovo Pod non parte e va in stato `ImagePullBackOff` o `ErrImagePull`. I vecchi Pod restano attivi (Rolling Update).
*   **Evidenze:**
    ```text
    $ kubectl describe pod -n demo -l app=podinfo
    ...
    Events:
      Warning  Failed  12s   kubelet  Failed to pull image "stefanprodan/podinfo:6.4.0-inesistente": rpc error: code = NotFound desc = failed to pull and unpack image...
    ```
*   **Diagnosi:** Il tag dell'immagine specificato non esiste nel registry pubblico.
*   **Correzione (Rollback):** Annullare l'ultima modifica al Deployment.
    ```bash
    kubectl rollout undo deployment/podinfo -n demo
    kubectl rollout status deployment/podinfo -n demo --timeout=120s
    kubectl get pods -n demo -l app=podinfo
    kubectl get deployment podinfo -n demo
    ```
*   **Escalation:** Se il tag è corretto ma il pull fallisce, potrebbe essere un rate-limit di Docker Hub o un problema di rete del nodo. In tal caso, fornire l'output completo di `describe` al team infrastrutturale.

### Scenario 2: Connection Refused (Service TargetPort errato)
*   **Riproduzione:** Modificare il `targetPort` del Service in modo che punti a una porta chiusa.
    ```bash
    kubectl patch svc podinfo -n demo --type=json -p='[{"op":"replace","path":"/spec/ports/0/targetPort","value":9999}]'
    ```
*   **Sintomo:** L'applicazione non risponde nel browser (`ERR_CONNECTION_REFUSED`), ma il Pod è in stato `Running 1/1`.
*   **Evidenze:**
    ```bash
    kubectl get endpointslice -n demo -l kubernetes.io/service-name=podinfo -o yaml
    kubectl describe svc podinfo -n demo
    ```
    Nell'EndpointSlice verificare che la porta indicata in `ports` sia `9999`. Nel `describe svc` verificare che il `TargetPort` sia `9999/TCP`. L'indirizzo del Pod può essere presente: il problema è la porta di destinazione errata.
*   **Diagnosi:** Il Service inoltra il traffico a una porta su cui l'applicazione non è in ascolto.
*   **Correzione (Ripristino):** il `rollout undo` non ripristina il Service, perché è una risorsa distinta dal Deployment. In questo laboratorio il deploy viene eseguito tramite manifest Kubernetes: riapplicare il manifest ripristina il `targetPort` dichiarato.
    ```bash
    kubectl apply -f podinfo.yaml
    kubectl describe svc podinfo -n demo
    kubectl get endpointslice -n demo -l kubernetes.io/service-name=podinfo
    ```
*   **Escalation:** Se la porta è corretta, verificare le NetworkPolicy o i log dell'applicazione per eventuali crash interni.

### Scenario 3: CrashLoopBackOff (Errore applicativo)
*   **Riproduzione:** Iniettare un comando di errore nel container.
    ```bash
    kubectl patch deployment podinfo -n demo --type=json -p='[{"op":"add","path":"/spec/template/spec/containers/0/command","value":["/bin/sh","-c","echo Errore Fatale && exit 1"]}]'
    ```
*   **Sintomo:** Il Pod si riavvia in continuazione. Lo stato passa da `Running` a `Error` e poi `CrashLoopBackOff`. Il contatore `RESTARTS` aumenta.
*   **Evidenze:**
    ```text
    $ kubectl logs -n demo -l app=podinfo --previous
    Errore Fatale

    $ kubectl describe pod -n demo -l app=podinfo
    Last State: Terminated, Reason: Error, Exit Code: 1
    ```
*   **Diagnosi:** L'applicazione termina con un errore logico durante l'avvio. Kubernetes la riavvia, ma il problema persiste.
*   **Correzione (Rollback):** Annullare la modifica.
    ```bash
    kubectl rollout undo deployment/podinfo -n demo
    kubectl rollout status deployment/podinfo -n demo --timeout=120s
    kubectl get pods -n demo -l app=podinfo
    kubectl logs -n demo -l app=podinfo --tail=20
    ```
*   **Escalation:** Se l'errore è nel codice dell'applicazione (visibile dai log), fornire i log al team di sviluppo (L3).

### Scenario 4: Readiness Probe Failed (Pod non pronto)
*   **Riproduzione:** Modificare il path della `readinessProbe` a un endpoint inesistente.
    ```bash
    kubectl patch deployment podinfo -n demo --type=json -p='[{"op":"replace","path":"/spec/template/spec/containers/0/readinessProbe/httpGet/path","value":"/percorso-sbagliato"}]'
    ```
*   **Sintomo:** Il nuovo Pod rimane in stato `Running` ma mostra `READY 0/1` perché la readiness probe fallisce. Con una replica e la strategia RollingUpdate predefinita, il vecchio Pod può rimanere Ready e continuare a servire traffico. Il Service esclude il nuovo Pod non pronto dal traffico normale.*   **Evidenze:**
    ```text
    $ kubectl describe pod -n demo -l app=podinfo
    Warning  Unhealthy  5s   kubelet  Readiness probe failed: HTTP probe failed with statuscode: 404
    ```
*   **Diagnosi:** La readiness probe richiama un endpoint inesistente e riceve HTTP 404. Kubernetes non considera il nuovo Pod pronto e non lo utilizza come endpoint disponibile per il traffico normale del Service.
*   **Correzione (Rollback):** Annullare la modifica.
    ```bash
    kubectl rollout undo deployment/podinfo -n demo
    kubectl rollout status deployment/podinfo -n demo --timeout=120s
    kubectl get pods -n demo -l app=podinfo
    kubectl get endpointslice -n demo -l kubernetes.io/service-name=podinfo
    ```
*   **Escalation:** Se il path è corretto, verificare i log e l'uso di CPU/RAM. Se la liveness fallisse al posto della readiness, il container verrebbe riavviato in loop.

### Scenario 5: OOMKilled (Out Of Memory)
*   **Riproduzione:** Impostare un limite di memoria troppo basso per l'applicazione.
    ```bash
    kubectl set resources deployment/podinfo -n demo \
     --requests=memory=5Mi \
     --limits=memory=10Mi
    ```
*   **Sintomo:** Il container supera il limite di memoria e viene terminato dal kernel con motivo `OOMKilled`. Kubernetes tenta di riavviarlo; il Pod puo quindi mostrare `CrashLoopBackOff` nella colonna STATUS di `kubectl get pods`.
*   **Evidenze:**
    ```text
    $ kubectl describe pod -n demo -l app=podinfo
    Last State: Terminated
    Reason: OOMKilled
    Exit Code: 137
    ```
*   **Diagnosi:** L'applicazione ha superato il limite di RAM assegnato. Il kernel Linux ha ucciso il processo (SIGKILL, exit 137).
*   **Correzione (Rollback):** Annullare la modifica o aumentare il limite.
    ```bash
    kubectl rollout undo deployment/podinfo -n demo
    kubectl rollout status deployment/podinfo -n demo --timeout=120s
    kubectl get pods -n demo -l app=podinfo
    kubectl describe deployment podinfo -n demo
    ```
*   **Escalation:** Se il consumo di memoria supera ripetutamente il limite configurato, raccogliere metriche e log per verificare se si tratta di un fabbisogno applicativo legittimo o di un possibile memory leak. Se necessario, richiedere una revisione dei memory limits e verificare la capacità allocabile del nodo con il team infrastrutturale.
---

## 3. Criteri Generali di Escalation

L'operatore L2 deve aprire un ticket verso il team di sviluppo (L3) o infrastruttura se:
1.  Il problema persiste dopo aver corretto il manifest e riavviato il Pod.
2.  L'anomalia è chiaramente causata da un errore nel codice dell'applicazione.
3.  Il problema riguarda i nodi (es. `NotReady` o risorse esaurite).

**Informazioni obbligatorie da allegare al ticket di escalation:**
*   Namespace e nome del Pod.
*   Output completo di `kubectl describe pod`.
*   Eventi del cluster (`kubectl get events`).
*   Ultime 50-100 righe di log (`kubectl logs --previous` se il Pod è crashato).
*   Orario dell'accaduto e azioni già intraprese per la risoluzione.