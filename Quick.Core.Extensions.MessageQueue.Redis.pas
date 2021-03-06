{ ***************************************************************************

  Copyright (c) 2016-2020 Kike P�rez

  Unit        : Quick.Core.Extensions.MessageQueue.Redis
  Description : Core Redis MessageQueue Extension
  Author      : Kike P�rez
  Version     : 1.0
  Created     : 07/07/2020
  Modified    : 12/07/2020

  This file is part of QuickCore: https://github.com/exilon/QuickCore

 ***************************************************************************

  Licensed under the Apache License, Version 2.0 (the "License");
  you may not use this file except in compliance with the License.
  You may obtain a copy of the License at

  http://www.apache.org/licenses/LICENSE-2.0

  Unless required by applicable law or agreed to in writing, software
  distributed under the License is distributed on an "AS IS" BASIS,
  WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
  See the License for the specific language governing permissions and
  limitations under the License.

 *************************************************************************** }

unit Quick.Core.Extensions.MessageQueue.Redis;

{$i QuickCore.inc}

interface

uses
  {$IFDEF DEBUG_MSQ}
  Quick.Debug.Utils,
  {$ENDIF}
  System.SysUtils,
  System.DateUtils,
  Quick.Commons,
  Quick.Options,
  Quick.Threads,
  Quick.Pooling,
  Quick.Data.Redis,
  Quick.Core.Logging.Abstractions,
  Quick.Core.MessageQueue.Abstractions,
  Quick.Core.MessageQueue,
  Quick.Core.DependencyInjection;

type
  TRealiableMessageQueue = class
  private
    fCheckHangedMessagesIntervalSec : Integer;
    fEnabled: Boolean;
    fDetermineAsHangedAfterSec: Integer;
  published
    property CheckHangedMessagesIntervalSec : Integer read fCheckHangedMessagesIntervalSec write fCheckHangedMessagesIntervalSec;
    property DetermineAsHangedAfterSec : Integer read fDetermineAsHangedAfterSec write fDetermineAsHangedAfterSec;
    property Enabled : Boolean read fEnabled write fEnabled;
  end;

  TRedisMessageQueueOptions = class(TOptions)
  private
    fHost : string;
    fPort : Integer;
    fDatabase : Integer;
    fKey : string;
    fPassword : string;
    fPopTimeoutSec : Integer;
    fMaxProducersPool : Integer;
    fMaxConsumersPool : Integer;
    fConnectionTimeout: Integer;
    fReadTimeout: Integer;
    fRealiableMessageQueue: TRealiableMessageQueue;
  public
    constructor Create; override;
    destructor Destroy; override;
  published
    property Host : string read fHost write fHost;
    property Port : Integer read fPort write fPort;
    property Database : Integer read fDatabase write fDatabase;
    property Key : string read fKey write fKey;
    property Password : string read fPassword write fPassword;
    property ConnectionTimeout : Integer read fConnectionTimeout write fConnectionTimeout;
    property ReadTimeout : Integer read fReadTimeout write fReadTimeout;
    property PopTimeoutSec : Integer read fPopTimeoutSec write fPopTimeoutSec;
    property MaxProducersPool : Integer read fMaxProducersPool write fMaxProducersPool;
    property MaxConsumersPool : Integer read fMaxConsumersPool write fMaxConsumersPool;
    property ReliableMessageQueue : TRealiableMessageQueue read fRealiableMessageQueue write fRealiableMessageQueue;
  end;

  TRedisMessageQueue<T : class, constructor> = class(TMessageQueue<T>)
  private
    fOptions : TRedisMessageQueueOptions;
    fPushRedisPool : TObjectPool<TRedisClient>;
    fPopRedisPool : TObjectPool<TRedisClient>;
    fScheduler : TScheduledTasks;
    fLogger : ILogger;
    fWorkingKey : string;
    fFailedKey : string;
    procedure ConfigureRedisPooling;
    procedure CreateScheduler;
    function CreateRedisPool(aMaxPool, aConnectionTimemout, aReadTimeout : Integer) : TObjectPool<TRedisClient>;
    procedure CreateJobs;
    procedure EnqueueHangedMessages;
  public
    constructor Create(aOptions : IOptions<TRedisMessageQueueOptions>; aLogger : ILogger);
    destructor Destroy; override;
    function Push(const aMessage : T) : TMSQWaitResult; override;
    function Pop(out oMessage : T) : TMSQWaitResult; override;
    function Remove(const aMessage : T) : Boolean; override;
    function Failed(const aMessage : T) : Boolean; override;
  end;

  TMessageQueueServiceExtension = class(TServiceCollectionExtension)
  public
    procedure AddRedisMessageQueue<T : class, constructor>(aOptionsProc : TConfigureOptionsProc<TRedisMessageQueueOptions>);
  end;

implementation

{ TRedisMessageQueue<T> }

function  TRedisMessageQueue<T>.CreateRedisPool(aMaxPool, aConnectionTimemout, aReadTimeout : Integer) : TObjectPool<TRedisClient>;
begin
  Result := TObjectPool<TRedisClient>.Create(aMaxPool,30000,procedure(var aRedis : TRedisClient)
      begin
        aRedis := TRedisClient.Create;
        aRedis.Host := fOptions.Host;
        aRedis.Port := fOptions.Port;
        aRedis.Password := fOptions.Password;
        aRedis.DataBaseNumber := fOptions.Database;
        aRedis.MaxSize := 0;
        aRedis.ConnectionTimeout := aConnectionTimemout;
        aRedis.ReadTimeout := aReadTimeout;
        aRedis.Connect;
      end);
end;

procedure TRedisMessageQueue<T>.CreateScheduler;
begin
  fScheduler := TScheduledTasks.Create;
  CreateJobs;
  fScheduler.Start;
end;

constructor TRedisMessageQueue<T>.Create(aOptions: IOptions<TRedisMessageQueueOptions>; aLogger: ILogger);
begin
  inherited Create;
  fOptions := aOptions.Value;
  fWorkingKey := fOptions.Key + '.working';
  if fOptions.ReliableMessageQueue.Enabled then CreateScheduler;
  ConfigureRedisPooling;
end;

procedure TRedisMessageQueue<T>.CreateJobs;
begin
  inherited;
  begin
    fScheduler.AddTask('EnqueueHangedMessages',procedure (task : ITask)
                  begin
                    EnqueueHangedMessages;
                  end
                  ).OnException(procedure(task : ITask; aException : Exception)
                  begin
                    fLogger.Error('RedisMSQ EnqueueHangedMessages Job error: %s',[aException.Message]);
                  end
                  ).StartInSeconds(fOptions.ReliableMessageQueue.CheckHangedMessagesIntervalSec)
                  .RepeatEvery(fOptions.ReliableMessageQueue.CheckHangedMessagesIntervalSec,TTimeMeasure.tmSeconds);
  end;
end;

procedure TRedisMessageQueue<T>.ConfigureRedisPooling;
begin
  fPushRedisPool := CreateRedisPool(fOptions.MaxProducersPool,fOptions.ConnectionTimeout,fOptions.ReadTimeout);
  fPopRedisPool := CreateRedisPool(fOptions.MaxConsumersPool,fOptions.ConnectionTimeout, (fOptions.PopTimeoutSec + 5) * 1000);
end;

destructor TRedisMessageQueue<T>.Destroy;
begin
  if Assigned(fPushRedisPool) then fPushRedisPool.Free;
  if Assigned(fPopRedisPool) then fPopRedisPool.Free;
  if Assigned(fScheduler) then
  begin
    fScheduler.Stop;
    fScheduler.Free;
  end;
  inherited;
end;

procedure TRedisMessageQueue<T>.EnqueueHangedMessages;
var
  redis : TRedisClient;
  i : Integer;
  resarray : TArray<TRedisSortedItem>;
  value : string;
  ttl : Integer;
  limitTime : Int64;
begin
  limitTime := DateTimeToUnix(IncSecond(Now(),fOptions.ReliableMessageQueue.DetermineAsHangedAfterSec * -1));
  {$IFDEF DEBUG_MSQ}
  TDebugger.Trace(Self,Format('EnqueueHangedMessages LimitTime %d',[limitTime]));
  {$ENDIF}
  redis := fPushRedisPool.Get.Item;
  resarray := redis.RedisZRANGEBYSCORE(fWorkingKey,0,limittime);
  {$IFDEF DEBUG_MSQ}
  TDebugger.Trace(Self,Format('EnqueueHangedMessages resarray.count %d',[High(resarray)]));
  {$ENDIF}
  for i := 0 to High(resarray) do
  begin
    {$IFDEF DEBUG_MSQ}
    TDebugger.Trace(Self,Format('EnqueueHangedMessages: remove id: %d / value: %s',[resarray[i].Score,resarray[i].Value]));
    {$ENDIF}
    if redis.RedisZREM(fWorkingKey,resarray[i].Value) then
    begin
      if not redis.RedisLPUSH(fOptions.Key,resarray[i].Value) then
      begin
        {$IFDEF DEBUG_MSQ}
        TDebugger.Trace(Self,Format('EnqueueHangedMessages: %s cannot be re-enqueued',[resarray[i].value]));
        {$ENDIF}
      end;
    end
    else
    begin
      {$IFDEF DEBUG_MSQ}
      TDebugger.Trace(Self,Format('EnqueueHangedMessages: %s cannot be deleted',[resarray[i].value]));
      {$ENDIF}
    end;
  end;
end;

function TRedisMessageQueue<T>.Push(const aMessage: T) : TMSQWaitResult;
begin
  try
    if fPushRedisPool.Get.Item.RedisLPUSH(fOptions.Key,Serialize(aMessage)) then Result := TMSQWaitResult.wrOk
      else Result := TMSQWaitResult.wrTimeout;
  except
    Result := TMSQWaitResult.wrError;
  end;
end;

function TRedisMessageQueue<T>.Pop(out oMessage: T) : TMSQWaitResult;
var
  msg : string;
  done : Boolean;
begin
  try
    done := fPopRedisPool.Get.Item.RedisBRPOP(fOptions.Key,msg,fOptions.PopTimeoutSec);

    if done then
    begin
      if fOptions.ReliableMessageQueue.Enabled then
      begin
        fPushRedisPool.Get.Item.redisZADD(fWorkingKey,msg,DateTimeToUnix(Now));
      end;
      oMessage := Deserialize(msg);
      Result := TMSQWaitResult.wrOk;
    end
    else Result := TMSQWaitResult.wrTimeout;
  except
    Result := TMSQWaitResult.wrError;
  end;
end;

function TRedisMessageQueue<T>.Remove(const aMessage: T): Boolean;
var
  key : string;
begin
  if fOptions.ReliableMessageQueue.Enabled then key := fWorkingKey
    else key := fOptions.Key;

  Result := fPushRedisPool.Get.Item.RedisLREM(key,Serialize(aMessage),-1);
end;

function TRedisMessageQueue<T>.Failed(const aMessage: T): Boolean;
var
  key : string;
begin
  if fOptions.ReliableMessageQueue.Enabled then key := fWorkingKey
    else key := fOptions.Key;

  Result := fPushRedisPool.Get.Item.RedisLREM(key,Serialize(aMessage),-1);
  Result := fPushRedisPool.Get.Item.RedisLPUSH(fFailedKey,Serialize(aMessage));
end;

{ TQueueServiceExtension }

procedure TMessageQueueServiceExtension.AddRedisMessageQueue<T>(aOptionsProc: TConfigureOptionsProc<TRedisMessageQueueOptions>);
var
  options : TRedisMessageQueueOptions;
begin
  options := TRedisMessageQueueOptions.Create;
  options.Name := 'RedisMessageQueue';
  if Assigned(aOptionsProc) then aOptionsProc(options);

  ServiceCollection.Configure<TRedisMessageQueueOptions>(options);
  ServiceCollection.AddSingleton<IMessageQueue<T>,TRedisMessageQueue<T>>();
end;

{ TRedisMessageQueueOptions }

constructor TRedisMessageQueueOptions.Create;
begin
  fHost := 'localhost';
  fPort := 6379;
  fDatabase := 0;
  fPopTimeoutSec := 30;
  fConnectionTimeout := 20000;
  fReadTimeout := 10000;
  fMaxProducersPool := 10;
  fMaxConsumersPool := 10;
  fRealiableMessageQueue := TRealiableMessageQueue.Create;
  fRealiableMessageQueue.CheckHangedMessagesIntervalSec := 300;
  fRealiableMessageQueue.DetermineAsHangedAfterSec := 60;
  fRealiableMessageQueue.Enabled := False;
end;

destructor TRedisMessageQueueOptions.Destroy;
begin
  fRealiableMessageQueue.Free;
  inherited;
end;

end.
