//+------------------------------------------------------------------+
//|                     AlfredAI_Alerts.mqh                          |
//|                   Copyright 2025, AlfredAI Project               |
//|                 https://github.com/rudikai/alfredai              |
//+------------------------------------------------------------------+
#ifndef ALFREDAI_ALERTS_MQH
#define ALFREDAI_ALERTS_MQH

#property strict

#include "AlfredAI_Utils.mqh"
#include "AlfredAI_Config.mqh"
#include "AlfredAI_Journal.mqh"

class AAI_Alerts
  {
private:
   bool   m_pushEnabled;
   bool   m_tgEnabled;
   string m_tgToken;
   string m_tgChatId;
   string m_tgApiBase;
   int    m_timeoutMs;

   // Minimal ASCII URL-encode (0x20..0x7E). Non-ASCII -> percent-encoded.
   static string URLEncodeAscii(const string s)
     {
      string out="";
      const int len=(int)StringLen(s);
      for(int i=0;i<len;i++)
        {
         ushort ch=(ushort)StringGetCharacter(s,i);
         if((ch>='A' && ch<='Z') || (ch>='a' && ch<='z') || (ch>='0' && ch<='9') ||
            ch=='-' || ch=='_' || ch=='.' || ch=='~')
           out+=(string)ch;
         else if(ch==' ')
           out+="%20";
         else
           out+=StringFormat("%%%02X",(int)(ch & 0xFF));
        }
      return out;
     }

   bool TelegramGET(const string url)
     {
      if(StringLen(url)==0) return false;
      string headers="";
      uchar  body[];         // empty
      uchar  reply[];
      string reply_headers="";
      int    status=WebRequest("GET",url,headers, m_timeoutMs, body, reply, reply_headers);
      return (status==200);
     }

public:
               AAI_Alerts():m_pushEnabled(true),m_tgEnabled(false),m_tgToken(""),
                           m_tgChatId(""),m_tgApiBase("https://api.telegram.org"),
                           m_timeoutMs(7000) {}

   bool      Init(AAI_Config &cfg)
     {
      m_pushEnabled = (cfg.GetI("PushEnabled",1)!=0);
      m_tgEnabled   = (cfg.GetI("TelegramEnabled",0)!=0);
      m_tgToken     = cfg.Get("TelegramBotToken","");
      m_tgChatId    = cfg.Get("TelegramChatId","");
      string base   = cfg.Get("TelegramApiBase","https://api.telegram.org");
      if(StringLen(base)>0) m_tgApiBase=base;
      m_timeoutMs   = 7000;
      return true;
     }

   bool      SendPush(const string msg)
     {
      if(!m_pushEnabled) return false;
      if(StringLen(msg)==0) return false;
      return SendNotification(msg);
     }

   bool      SendTelegram(const string msg)
     {
      if(!m_tgEnabled) return false;
      if(StringLen(m_tgToken)==0 || StringLen(m_tgChatId)==0) return false;

      string url = StringFormat("%s/bot%s/sendMessage?chat_id=%s&text=%s",
                                m_tgApiBase, m_tgToken, m_tgChatId, URLEncodeAscii(msg));
      return TelegramGET(url);
     }

   // Journals every alert as event=Alert (AAI k=v line). Returns true if any channel succeeded.
   bool      Notify(AAI_Journal &journal,
                     const string module,const string reason,const string message,
                     const string symbol,ENUM_TIMEFRAMES tf)
     {
      bool ok=false;
      if(m_pushEnabled)   ok |= SendPush(message);
      if(m_tgEnabled)     ok |= SendTelegram(message);

      double bal=AccountInfoDouble(ACCOUNT_BALANCE);
      journal.Write(module,"Alert",symbol,tf,
                     0,0,"",         // position_id, order_id, action
                     0.0,0.0,0.0,0.0,// price, qty, sl, tp
                     reason,"",      // reason, tag
                     0.0,bal,
                     message);       // comment
      return ok;
     }
  };

#endif // ALFREDAI_ALERTS_MQH

