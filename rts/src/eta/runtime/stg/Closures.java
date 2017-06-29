package eta.runtime.stg;

/* - Utilies for working with Closures from the Java side.
   - Standard closures used throughout the runtime system. */

public class Closures {

    /* Standard Closures */

    public static final Closure False             = null;
    public static final Closure flushStdHandles   = null;
    public static final Closure runSparks         = null;
    public static final Closure nonTermination    = null;
    public static final Closure nestedAtomically  = null;
    public static final Closure runFinalizerBatch = null;

    static {
        try {
            False             = loadClosure("ghc_prim.ghc.Types", "False");
            flushStdHandles   = loadClosure("base.ghc.TopHandler", "flushStdHandles");
            runSparks         = loadClosure("base.ghc.conc.Sync", "runSparks");
            nonTermination    = loadClosure("base.control.exception.Base", "nonTermination");
            nestedAtomically  = loadClosure("base.control.exception.Base", "nestedAtomically");
            runFinalizerBatch = loadClosure("base.ghc.Weak", "runFinalizerBatch");
        } catch (Exception e) {
            System.err.println("FATAL ERROR: Failed to load base closures.");
            e.printStackTrace();
            System.exit(1);
        }
    }

    /* TODO:
       Make this convert user writable closure names to the internal representation.

       Example: base:GHC.Conc.Sync.runSparks -> base.ghc.conc.Sync, runSparks
    */
    public static Closure loadClosure(String className, String closureName) {
        return (Closure) Class.forName(className).getMethod(closureName).invoke(null);
    }

    /* Standard Constructors */
    public static final Class Int = Class.forName("ghc_prim.ghc.Types$IzhD");

    /* Closures for Main Evaluation */

    public static final Closure evalLazyIO(Closure p) {
        return new EvalLazyIO(p);
    }

    public static final Closure evalIO(Closure p) {
        return new EvalIO(p);
    }

    private static final Closure evalJava(Object thisObj, Closure p) {
        return new EvalJava(thisObj, p);
    }

    private static class EvalLazyIO extends Closure {
        private final Closure p;

        public EvalLazyIO(Closure p) {
            this.p = p;
        }

        @Override
        public Closure enter(StgContext context) {
            Closure result;
            try {
                result = p.evaluate(context).applyV(context);
                tso.whatNext = ThreadComplete;
            } catch (EtaException e) {
                tso.whatNext = ThreadKilled;
                result = e.exception;
            } catch (EtaAsyncException e) {
                tso.whatNext = ThreadKilled;
                result = e.exception;
            }
            return result;
        }
    }

    private static class EvalIO extends Closure {
        private final Closure p;

        public EvalIO(Closure p) {
            this.p = p;
        }

        @Override
        public Closure enter(StgContext context) {
            Closure result;
            try {
                result = p.evaluate(context).applyV(context).evaluate(context);
                tso.whatNext = ThreadComplete;
            } catch (EtaException e) {
                tso.whatNext = ThreadKilled;
                result = e.exception;
            } catch (EtaAsyncException e) {
                tso.whatNext = ThreadKilled;
                result = e.exception;
            }
            return result;
        }
    }

    public static class EvalJava extends Closure {
        private final Object  thisObj;
        private final Closure p;

        public EvalJava(Object thisObj, Closure p) {
            this.thisObj = thisObj;
            this.p       = p;
        }

        @Override
        public Closure enter(StgContext context) {
            Closure result;
            try {
                result = p.evaluate(context).applyO(context, thisObj).evaluate(context);
                tso.whatNext = ThreadComplete;
            } catch (EtaException e) {
                tso.whatNext = ThreadKilled;
                result = e.exception;
            } catch (EtaAsyncException e) {
                tso.whatNext = ThreadKilled;
                result = e.exception;
            }
            return result;
        }
    }

    /* Closure Utilities */

    public static Closure force(Closure e) {
        return new Ap1Upd(e);
    }

    public static Closure apply(Closure e0, Closure e1) {
        return new Ap2Upd(e0, e1);
    }

    public static Closure apply(Closure e0, Closure e1, Closure e2) {
        return new Ap3Upd(e0, e1, e2);
    }

    public static Closure apply(Closure e0, Closure e1, Closure e2, Closure e3) {
        return new Ap4Upd(e0, e1, e2, e3);
    }

    public static Closure apply(Closure e0, Closure e1, Closure e2, Closure e3, Closure e4) {
        return new Ap5Upd(e0, e1, e2, e3, e4);
    }

    public static Closure apply(Closure e0, Closure e1, Closure e2, Closure e3, Closure e4, Closure e5) {
        return new Ap6Upd(e0, e1, e2, e3, e4, e5);
    }

    public static Closure apply(Closure e0, Closure e1, Closure e2, Closure e3, Closure e4, Closure e5, Closure e6) {
        return new Ap7Upd(e0, e1, e2, e3, e4, e5, e6);
    }

    public static Closure applyObject(Closure e, Object o) {
        return new ApO(e, o);
    }

    public static Closure mkInt(int i) {
        return (Closure) Int.newInstance(i);
    }

    /* TODO: Add utilities for constructing all the primitive types. */
}