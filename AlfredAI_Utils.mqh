//+------------------------------------------------------------------+
//|                       AlfredAI_Utils.mqh                         |
//|                   Copyright 2025, AlfredAI Project               |
//|                 https://github.com/rudikai/alfredai              |
//+------------------------------------------------------------------+
#ifndef ALFREDAI_UTILS_MQH
#define ALFREDAI_UTILS_MQH

#property strict

// ---------- Errors / constants ----------
enum AAI_Error
  {
   AAI_ERR_OK    = 0,
   AAI_ERR_FILE  = 1,
   AAI_ERR_PARAM = 2,
   AAI_ERR_STATE = 3
  };


// ---------- Optional static-method shim (AAI::Method()) ----------
class AAI
  {
public:
   static string NowIsoUtc()                                             { return AAI_NowIsoUtc(); }
   static string PadLeft(const string s,int w,char c)                    { return AAI_PadLeft(s,w,c); }
   static string DoubleToStrFix(double v,int digits)                     { return AAI_DoubleToStrFix(v,digits); }
   static string JoinKV(string &keys[],string &vals[],const string sep)   { return AAI_JoinKV(keys,vals,sep); }
   static string TFToString(ENUM_TIMEFRAMES tf)                          { return AAI_TFToString(tf); }
   static bool   EnsureTimer(int seconds)                                { return AAI_EnsureTimer(seconds); }
   static bool   FileRotate(const string base,int max_backups,long max_bytes) { return AAI_FileRotate(base,max_backups,max_bytes); }
   static string TradeRetcodeToString(int retcode)                       { return AAI_TradeRetcodeToString(retcode); }
  };

// ---------- Implementations ----------
string AAI_NowIsoUtc()
  {
   MqlDateTime st;
   TimeToStruct(TimeGMT(),st);
   return StringFormat("%04d-%02d-%02dT%02d:%02d:%02dZ",
                       st.year,st.mon,st.day,st.hour,st.min,st.sec);
  }

string AAI_PadLeft(const string s,int w,char c)
  {
   int len=(int)StringLen(s);
   if(len>=w) return s;
   string pad="";
   for(int i=0;i<w-len;i++) pad+=(string)c; // Explicit cast to string
   return pad+s;
  }

string AAI_DoubleToStrFix(double v,int digits)
  {
   return DoubleToString(v,digits);
  }

string AAI_JoinKV(string &keys[], string &vals[], const string sep)
  {
   int n=ArraySize(keys);
   if(n<=0 || n!=ArraySize(vals)) return "";
   string out="";
   for(int i=0;i<n;i++)
     {
      if(i>0) out+=sep;
      out+=keys[i];
      out+="="; // Use string literal
      out+=vals[i];
     }
   return out;
  }

string AAI_TFToString(ENUM_TIMEFRAMES tf)
  {
   switch(tf)
     {
      case PERIOD_M1:  return "M1";
      case PERIOD_M2:  return "M2";
      case PERIOD_M3:  return "M3";
      case PERIOD_M4:  return "M4";
      case PERIOD_M5:  return "M5";
      case PERIOD_M6:  return "M6";
      case PERIOD_M10: return "M10";
      case PERIOD_M12: return "M12";
      case PERIOD_M15: return "M15";
      case PERIOD_M20: return "M20";
      case PERIOD_M30: return "M30";
      case PERIOD_H1:  return "H1";
      case PERIOD_H2:  return "H2";
      case PERIOD_H3:  return "H3";
      case PERIOD_H4:  return "H4";
      case PERIOD_H6:  return "H6";
      case PERIOD_H8:  return "H8";
      case PERIOD_H12: return "H12";
      case PERIOD_D1:  return "D1";
      case PERIOD_W1:  return "W1";
      case PERIOD_MN1: return "MN1";
      default:         return "TF?";
     }
  }

// Use a small static guard; there is no safe TerminalInfoInteger flag for timer state.
bool AAI_EnsureTimer(int seconds)
  {
   static int s_current = -1;
   if(seconds<=0)
     {
      EventKillTimer();
      s_current = -1;
      return true;
     }
   if(s_current==seconds) return true;
   // reset and set to the new cadence
   EventKillTimer();
   bool ok = EventSetTimer(seconds);
   if(ok) s_current=seconds; else s_current=-1;
   return ok;
  }

// Rotate base file when it exceeds max_bytes. Uses 4-arg FileMove signature.
bool AAI_FileRotate(const string base,int max_backups,long max_bytes)
  {
   if(max_backups<1 || max_bytes<=0) return false;

   // Probe current size safely
   ulong size=0; // Use ulong to match FileSize() return type
   if(FileIsExist(base))
     {
      int h=FileOpen(base,FILE_READ|FILE_BIN|FILE_SHARE_READ|FILE_SHARE_WRITE);
      if(h!=INVALID_HANDLE)
        {
         size = FileSize(h);
         FileClose(h);
        }
     }
   if(size<=(ulong)max_bytes) return false;

   // Delete the oldest
   string oldest = StringFormat("%s.%d",base,max_backups);
   if(FileIsExist(oldest))
       FileDelete(oldest);

   // Shift N-1 .. 1 upward
   for(int k=max_backups-1; k>=1; --k)
     {
      string src = StringFormat("%s.%d",base,k);
      string dst = StringFormat("%s.%d",base,k+1);
      if(FileIsExist(src))
        {
         // If a destination exists, remove it before moving
         if(FileIsExist(dst)) FileDelete(dst);
         // 4-parameter form: (src, common_src=0, dst, common_dst=0)
         FileMove(src,0,dst,0);
        }
     }

   // Move base -> .1
   string first = StringFormat("%s.%d",base,1);
   if(FileIsExist(first)) FileDelete(first);
   FileMove(base,0,first,0);

   return true;
  }

//+------------------------------------------------------------------+
//| Converts an MQL5 trade return code to a readable string.         |
//+------------------------------------------------------------------+
string AAI_TradeRetcodeToString(int retcode)
{
   switch(retcode)
   {
      case TRADE_RETCODE_REQUOTE:          return "REQUOTE";
      case TRADE_RETCODE_REJECT:           return "REJECT";
      case TRADE_RETCODE_CANCEL:           return "CANCEL";
      case TRADE_RETCODE_PLACED:           return "PLACED";
      case TRADE_RETCODE_DONE:             return "DONE";
      case TRADE_RETCODE_DONE_PARTIAL:     return "DONE_PARTIAL";
      case TRADE_RETCODE_ERROR:            return "ERROR";
      case TRADE_RETCODE_TIMEOUT:          return "TIMEOUT";
      case TRADE_RETCODE_INVALID:          return "INVALID";
      case TRADE_RETCODE_INVALID_VOLUME:   return "INVALID_VOLUME";
      case TRADE_RETCODE_INVALID_PRICE:    return "INVALID_PRICE";
      case TRADE_RETCODE_INVALID_STOPS:    return "INVALID_STOPS";
      case TRADE_RETCODE_TRADE_DISABLED:   return "TRADE_DISABLED";
      case TRADE_RETCODE_MARKET_CLOSED:    return "MARKET_CLOSED";
      case TRADE_RETCODE_NO_MONEY:         return "NO_MONEY";
      case TRADE_RETCODE_PRICE_CHANGED:    return "PRICE_CHANGED";
      case TRADE_RETCODE_PRICE_OFF:        return "PRICE_OFF";
      case TRADE_RETCODE_INVALID_EXPIRATION: return "INVALID_EXPIRATION";
      case TRADE_RETCODE_ORDER_CHANGED:    return "ORDER_CHANGED";
      case TRADE_RETCODE_TOO_MANY_REQUESTS:return "TOO_MANY_REQUESTS";
      case TRADE_RETCODE_NO_CHANGES:       return "NO_CHANGES";
      case TRADE_RETCODE_SERVER_DISABLES_AT: return "SERVER_DISABLES_AT";
      case TRADE_RETCODE_CLIENT_DISABLES_AT: return "CLIENT_DISABLES_AT";
      case TRADE_RETCODE_LOCKED:           return "LOCKED";
      case TRADE_RETCODE_FROZEN:           return "FROZEN";
      case TRADE_RETCODE_INVALID_FILL:     return "INVALID_FILL";
      case TRADE_RETCODE_CONNECTION:       return "CONNECTION";
      case TRADE_RETCODE_ONLY_REAL:        return "ONLY_REAL";
      case TRADE_RETCODE_LIMIT_ORDERS:     return "LIMIT_ORDERS";
      case TRADE_RETCODE_LIMIT_VOLUME:     return "LIMIT_VOLUME";
      case TRADE_RETCODE_INVALID_ORDER:    return "INVALID_ORDER";
      case TRADE_RETCODE_POSITION_CLOSED:  return "POSITION_CLOSED";
      default:                             return IntegerToString(retcode);
   }
}
#endif // ALFREDAI_UTILS_MQH

