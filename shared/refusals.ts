/**
 * Why the server turned an upload away, in words a player can act on. Sync shows this in its
 * status line and the account page shows the last one, so the same wording lives here.
 */
export interface RefusalAdvice {
  /** What went wrong, one short sentence without a full stop. */
  summary: string;
  /** What to do about it, one short sentence without a full stop. */
  remedy: string;
  /** True when sending the same scan again can never help. */
  permanent: boolean;
}

const ACCOUNT = 'ahledger.com/account';

/**
 * @param status  HTTP status the server answered with.
 * @param reason  The `error` field of its JSON body (or the raw body).
 * @param skewSeconds  Server time minus the client's request time, when the client knows it;
 *   positive when the client's clock is behind.
 */
export function refusalAdvice(
  status: number,
  reason: string,
  skewSeconds?: number | null,
): RefusalAdvice {
  const r = (reason || '').toLowerCase();
  const skew = skewSeconds ?? null;
  if (status === 401) {
    // The server names the key when the secret sent belongs to another key on the account. That
    // signature verified with the request's own time, so the clock is not the problem, whatever
    // the skew; only a "clock window" refusal is about the clock for certain.
    const other = /bad signature: the secret belongs to your key (ahl_[a-z0-9]{16})/.exec(r)?.[1];
    if (other && !r.includes('clock window')) {
      return {
        summary: `the secret is from your other key ${other}, not from this key id`,
        remedy: `press Connect with ahledger.com in AHledger sync, which makes a new key and fills in both its key id and secret, then revoke the keys you no longer use on ${ACCOUNT}`,
        permanent: false,
      };
    }
    if (r.includes('clock window') || (skew !== null && Math.abs(skew) > 120)) {
      const minutes = skew === null ? null : Math.round(Math.abs(skew) / 60);
      const off =
        minutes === null
          ? 'more than five minutes off'
          : `${minutes} minute${minutes === 1 ? '' : 's'} ${(skew ?? 0) > 0 ? 'behind' : 'ahead'}`;
      return {
        summary: `your computer clock is ${off}`,
        remedy:
          'turn on automatic time (Windows: Settings, Time and language; macOS: System Settings, General, Date and Time), then press Upload now',
        permanent: false,
      };
    }
    if (r.includes('bad signature')) {
      // A secret is shown once, so pasting it again is rarely possible: Connect, or a new key.
      return {
        summary: 'the secret does not match this key id',
        remedy: `press Connect with ahledger.com in AHledger sync, or create a new key on ${ACCOUNT} and paste its key id and secret`,
        permanent: false,
      };
    }
    if (r.includes('unknown or revoked')) {
      return {
        summary: 'this key id is unknown or has been revoked',
        remedy: `create a new key on ${ACCOUNT} and paste it here`,
        permanent: false,
      };
    }
    return {
      summary: 'the request could not be authenticated',
      remedy: `check the key id and secret against ${ACCOUNT}`,
      permanent: false,
    };
  }
  if (status === 400) {
    if (r.includes('client but was sent as') || r.includes('client but were sent as')) {
      return {
        summary: r.includes('classic era client')
          ? 'this scan came from Classic Era, but the Game setting says Forever'
          : 'this scan came from Forever, but the Game setting says Classic Era',
        remedy: 'set Game in AHledger sync to the game you scanned in; new scans will then upload',
        permanent: true,
      };
    }
    if (r.includes('invalid realm name')) {
      return {
        summary: 'the realm name in this scan is not one the server accepts',
        remedy:
          'run a new scan; if it happens again, write in through the contact form with the realm name',
        permanent: true,
      };
    }
    if (r.includes('older than')) {
      return {
        summary: 'this scan is more than 7 days old, older than the server accepts',
        remedy: 'nothing to fix; run a new scan in game and it uploads normally',
        permanent: true,
      };
    }
    return {
      summary: `the server will never accept this scan (${reason || 'bad request'})`,
      remedy: 'run a new scan; if it happens again, update sync and the addon',
      permanent: true,
    };
  }
  if (status === 422) {
    return {
      summary: reason
        ? `the server cannot place this scan yet (${reason})`
        : 'the server cannot place this scan yet',
      remedy:
        'it is tried again on its own; if it stays refused for a day, write in through the contact form with the realm name',
      permanent: false,
    };
  }
  if (status === 409) {
    return {
      summary: 'the server saw this exact request already',
      remedy: 'nothing to do; the next scan uploads normally',
      permanent: true,
    };
  }
  if (status === 429) {
    return {
      summary: 'too many uploads in one minute',
      remedy: 'wait a minute; the next file change uploads normally',
      permanent: false,
    };
  }
  if (status >= 500) {
    return {
      summary: `the server is unavailable (HTTP ${status})`,
      remedy: 'nothing to do on your side; it is retried on the next change',
      permanent: false,
    };
  }
  return {
    summary: `the server answered HTTP ${status}${reason ? ` (${reason})` : ''}`,
    remedy: 'update sync and try again; if it persists, write in through the contact form',
    permanent: false,
  };
}
